// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// TODO remove when integrated
#![allow(unused)]

use anyhow::anyhow;
use async_trait::async_trait;
use axum::response::sse::Event;
use ethers::types::{Address, U256};
use serde::{Deserialize, Serialize};
use sui_json_rpc_types::EventPage;
use sui_json_rpc_types::{EventFilter, Page, SuiEvent};
use sui_sdk::{SuiClient as SuiSdkClient, SuiClientBuilder};
use sui_types::{
    base_types::{ObjectID, SuiAddress},
    digests::TransactionDigest,
    event::EventID,
    Identifier,
};
use tap::TapFallible;

use crate::error::{BridgeError, BridgeResult};

pub(crate) struct SuiClient<P> {
    inner: P,
}

impl SuiClient<SuiSdkClient> {
    pub async fn new(rpc_url: &str) -> anyhow::Result<Self> {
        let inner = SuiClientBuilder::default().build(rpc_url).await?;
        let self_ = Self { inner };
        self_.describe().await?;
        Ok(self_)
    }
}

impl<P> SuiClient<P>
where
    P: SuiClientInner,
{
    pub fn new_for_testing(inner: P) -> Self {
        Self { inner }
    }

    // TODO assert chain identifier
    async fn describe(&self) -> anyhow::Result<()> {
        let chain_id = self.inner.get_chain_identifier().await?;
        let block_number = self.inner.get_latest_checkpoint_sequence_number().await?;
        tracing::info!(
            "SuiClient is connected to chain {chain_id}, current block number: {block_number}"
        );
        Ok(())
    }

    /// Query Events that are defined in the given Move Module.
    /// The query processes paginates results in transaction granularity. Namely,
    /// unlike the typical event query cursor that uses EventID, the cursor here
    /// is a `TransactionDigest`` because we want to collect all related events
    /// in a transaction atomoically for easier downstream processing.
    pub async fn query_events_by_module(
        &self,
        package: ObjectID,
        module: Identifier,
        // Before we support query by checkpoint, we use tx_digest as cursor
        // Because the cursor is exclusive, it could be any tx that in the checkpoint
        // before which the query starts. Namely, if the query starts from checkpoint N,
        // the cursor could be any tx in checkpoint N-1.
        cursor: TransactionDigest,
    ) -> BridgeResult<Page<SuiEvent, TransactionDigest>> {
        let filter = EventFilter::MoveEventModule { package, module };
        let initial_cursor = EventID {
            tx_digest: cursor,
            // Cursor is exclusive, so we use a reasonably large number
            // (when the code is written the max event num in a tx is 1024)
            // to skip the cursor tx entirely.
            event_seq: u16::MAX as u64,
        };
        let mut cursor = initial_cursor;
        let mut is_first_page = true;
        let mut all_events: Vec<sui_json_rpc_types::SuiEvent> = vec![];
        loop {
            let events = self
                .inner
                .query_events(filter.clone(), cursor.clone())
                .await?;
            if events.data.is_empty() {
                return Ok(Page {
                    data: all_events,
                    next_cursor: Some(cursor.tx_digest),
                    has_next_page: false,
                });
            }

            // unwrap safe: we just checked data is not empty
            let new_cursor = events.data.last().unwrap().id.clone();

            // Now check if we need to query more events for the sake of
            // paginating in transaction granularity

            if !events.has_next_page {
                // A transaction's events shall be available all at once
                all_events.extend(events.data);
                return Ok(Page {
                    data: all_events,
                    next_cursor: Some(new_cursor.tx_digest),
                    has_next_page: false,
                });
            }

            if is_first_page {
                // the first page, take all returned events, go to next loop
                all_events.extend(events.data);
                cursor = new_cursor;
                is_first_page = false;
                continue;
            }

            // Not the first page, check if we collected all events in the tx
            let last_event_digest = events.data.last().map(|e| e.id.tx_digest);

            // We are done
            if last_event_digest != Some(cursor.tx_digest) {
                all_events.extend(
                    events
                        .data
                        .into_iter()
                        .take_while(|event| event.id.tx_digest == cursor.tx_digest),
                );
                return Ok(Page {
                    data: all_events,
                    next_cursor: Some(cursor.tx_digest),
                    has_next_page: true,
                });
            }

            // Returned events are all for the cursor tx and there are
            // potentially more, go to next loop.
            all_events.extend(events.data);
            cursor = new_cursor;
        }
    }

    pub async fn get_bridge_events_by_tx_digest(
        &self,
        tx_digest: &str,
    ) -> BridgeResult<Vec<SuiBridgeEvent>> {
        unimplemented!()
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SuiToEthBridgeEvent {
    pub source_address: SuiAddress,
    pub destination_address: Address,
    pub coin_name: String,
    pub amount: U256,
}

pub enum SuiBridgeEvent {
    SuiToEthBridge(SuiToEthBridgeEvent),
}

/// Use a trait to abstract over the SuiSDKClient and SuiMockClient for testing.
#[async_trait]
pub trait SuiClientInner: Send + Sync {
    type Error: Into<anyhow::Error> + Send + Sync + std::error::Error + 'static;
    async fn query_events(
        &self,
        query: EventFilter,
        cursor: EventID,
    ) -> Result<EventPage, Self::Error>;

    async fn get_chain_identifier(&self) -> Result<String, Self::Error>;

    async fn get_latest_checkpoint_sequence_number(&self) -> Result<u64, Self::Error>;
}

#[async_trait]
impl SuiClientInner for SuiSdkClient {
    type Error = sui_sdk::error::Error;

    async fn query_events(
        &self,
        query: EventFilter,
        cursor: EventID,
    ) -> Result<EventPage, Self::Error> {
        self.event_api()
            .query_events(query, Some(cursor), None, false)
            .await
    }

    async fn get_chain_identifier(&self) -> Result<String, Self::Error> {
        self.read_api().get_chain_identifier().await
    }

    async fn get_latest_checkpoint_sequence_number(&self) -> Result<u64, Self::Error> {
        self.read_api()
            .get_latest_checkpoint_sequence_number()
            .await
    }
}

#[cfg(test)]
mod tests {
    use crate::sui_mock_client::SuiMockClient;
    use ethers::types::{
        Address, Block, BlockNumber, Filter, FilterBlockOption, Log, ValueOrArray, U64,
    };
    use prometheus::Registry;
    use std::{collections::HashSet, str::FromStr};

    use super::*;

    #[tokio::test]
    async fn test_query_events_by_module() {
        // Note: for random events generated in this test, we only care about
        // tx_digest and event_seq, so it's ok that package and module does
        // not match the query parameters.
        telemetry_subscribers::init_for_testing();
        let mock_client = SuiMockClient::default();
        let sui_client = SuiClient::new_for_testing(mock_client.clone());
        let package = ObjectID::from_str("0xb71a9e").unwrap();
        let module = Identifier::from_str("BridgeTestModule").unwrap();

        // Case 1, empty response
        let mut cursor = TransactionDigest::random();
        let events = EventPage {
            data: vec![],
            next_cursor: None,
            has_next_page: false,
        };

        mock_client.add_event_response(
            package.clone(),
            module.clone(),
            EventID {
                tx_digest: cursor,
                event_seq: u16::MAX as u64,
            },
            events,
        );
        let page = sui_client
            .query_events_by_module(package, module.clone(), cursor.clone())
            .await
            .unwrap();
        assert_eq!(
            page,
            Page {
                data: vec![],
                next_cursor: Some(cursor),
                has_next_page: false,
            }
        );
        // only one query
        assert_eq!(
            mock_client.pop_front_past_event_query_params().unwrap(),
            (
                package.clone(),
                module.clone(),
                EventID {
                    tx_digest: cursor,
                    event_seq: u16::MAX as u64
                }
            )
        );
        assert_eq!(mock_client.pop_front_past_event_query_params(), None);

        // Case 2, only one page (has_next_page = false)
        let event = SuiEvent::random_for_testing();
        let events = EventPage {
            data: vec![event.clone()],
            next_cursor: None,
            has_next_page: false,
        };
        mock_client.add_event_response(
            package.clone(),
            module.clone(),
            EventID {
                tx_digest: cursor,
                event_seq: u16::MAX as u64,
            },
            events,
        );
        let page = sui_client
            .query_events_by_module(package, module.clone(), cursor.clone())
            .await
            .unwrap();
        assert_eq!(
            page,
            Page {
                data: vec![event.clone()],
                next_cursor: Some(event.id.tx_digest),
                has_next_page: false,
            }
        );
        // only one query
        assert_eq!(
            mock_client.pop_front_past_event_query_params().unwrap(),
            (
                package.clone(),
                module.clone(),
                EventID {
                    tx_digest: cursor,
                    event_seq: u16::MAX as u64
                }
            )
        );
        assert_eq!(mock_client.pop_front_past_event_query_params(), None);

        // Case 3, more than one pages, one tx has several events across pages
        // page 1 (event 1)
        let event_1 = SuiEvent::random_for_testing();
        let events_page_1 = EventPage {
            data: vec![event_1.clone()],
            next_cursor: Some(event_1.id.clone()),
            has_next_page: true,
        };
        mock_client.add_event_response(
            package.clone(),
            module.clone(),
            EventID {
                tx_digest: cursor,
                event_seq: u16::MAX as u64,
            },
            events_page_1,
        );
        // page 2 (event 1, event 2, same tx_digest)
        let mut event_2 = SuiEvent::random_for_testing();
        event_2.id.tx_digest = event_1.id.tx_digest;
        event_2.id.event_seq = event_1.id.event_seq + 1;
        let events_page_2 = EventPage {
            data: vec![event_2.clone()],
            next_cursor: Some(event_2.id.clone()),
            has_next_page: true,
        };
        mock_client.add_event_response(
            package.clone(),
            module.clone(),
            event_1.id.clone(),
            events_page_2,
        );
        // page 3 (event 3, event 4, different tx_digest)
        let mut event_3 = SuiEvent::random_for_testing();
        event_3.id.tx_digest = event_2.id.tx_digest;
        event_3.id.event_seq = event_2.id.event_seq + 1;
        let event_4 = SuiEvent::random_for_testing();
        assert_ne!(event_3.id.tx_digest, event_4.id.tx_digest);
        let events_page_3 = EventPage {
            data: vec![event_3.clone(), event_4.clone()],
            next_cursor: Some(event_4.id.clone()),
            has_next_page: true,
        };
        mock_client.add_event_response(
            package.clone(),
            module.clone(),
            event_2.id.clone(),
            events_page_3,
        );
        let page: Page<SuiEvent, TransactionDigest> = sui_client
            .query_events_by_module(package, module.clone(), cursor.clone())
            .await
            .unwrap();
        // Get back event_1, event_2 and event_2 because of transaction level granularity
        assert_eq!(
            page,
            Page {
                data: vec![event_1.clone(), event_2.clone(), event_3.clone()],
                next_cursor: Some(event_2.id.tx_digest),
                has_next_page: true,
            }
        );
        // first page
        assert_eq!(
            mock_client.pop_front_past_event_query_params().unwrap(),
            (
                package.clone(),
                module.clone(),
                EventID {
                    tx_digest: cursor.clone(),
                    event_seq: u16::MAX as u64
                }
            )
        );
        // second page
        assert_eq!(
            mock_client.pop_front_past_event_query_params().unwrap(),
            (package.clone(), module.clone(), event_1.id.clone())
        );
        // third page
        assert_eq!(
            mock_client.pop_front_past_event_query_params().unwrap(),
            (package.clone(), module.clone(), event_2.id.clone())
        );
        // no more
        assert_eq!(mock_client.pop_front_past_event_query_params(), None);

        // Case 4, modify page 3 in case 3 to return event_4 only
        let events_page_3 = EventPage {
            data: vec![event_4.clone()],
            next_cursor: Some(event_4.id.clone()),
            has_next_page: true,
        };
        mock_client.add_event_response(
            package.clone(),
            module.clone(),
            event_2.id.clone(),
            events_page_3,
        );
        let page: Page<SuiEvent, TransactionDigest> = sui_client
            .query_events_by_module(package, module.clone(), cursor.clone())
            .await
            .unwrap();
        assert_eq!(
            page,
            Page {
                data: vec![event_1.clone(), event_2.clone()],
                next_cursor: Some(event_2.id.tx_digest),
                has_next_page: true,
            }
        );
        // first page
        assert_eq!(
            mock_client.pop_front_past_event_query_params().unwrap(),
            (
                package.clone(),
                module.clone(),
                EventID {
                    tx_digest: cursor.clone(),
                    event_seq: u16::MAX as u64
                }
            )
        );
        // second page
        assert_eq!(
            mock_client.pop_front_past_event_query_params().unwrap(),
            (package.clone(), module.clone(), event_1.id.clone())
        );
        // third page
        assert_eq!(
            mock_client.pop_front_past_event_query_params().unwrap(),
            (package.clone(), module.clone(), event_2.id.clone())
        );
        // no more
        assert_eq!(mock_client.pop_front_past_event_query_params(), None);

        // Case 5, modity page 2 in case 3 to mark has_next_page as false
        let events_page_2 = EventPage {
            data: vec![event_2.clone()],
            next_cursor: Some(event_2.id.clone()),
            has_next_page: false,
        };
        mock_client.add_event_response(
            package.clone(),
            module.clone(),
            event_1.id.clone(),
            events_page_2,
        );
        let page: Page<SuiEvent, TransactionDigest> = sui_client
            .query_events_by_module(package, module.clone(), cursor.clone())
            .await
            .unwrap();
        assert_eq!(
            page,
            Page {
                data: vec![event_1.clone(), event_2.clone()],
                next_cursor: Some(event_2.id.tx_digest),
                has_next_page: false,
            }
        );
        // first page
        assert_eq!(
            mock_client.pop_front_past_event_query_params().unwrap(),
            (
                package.clone(),
                module.clone(),
                EventID {
                    tx_digest: cursor.clone(),
                    event_seq: u16::MAX as u64
                }
            )
        );
        // second page
        assert_eq!(
            mock_client.pop_front_past_event_query_params().unwrap(),
            (package.clone(), module.clone(), event_1.id.clone())
        );
        // no more
        assert_eq!(mock_client.pop_front_past_event_query_params(), None);
    }
}
