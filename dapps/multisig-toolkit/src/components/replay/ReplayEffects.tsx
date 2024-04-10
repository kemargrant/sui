// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { ReplayLink } from '@/components/replay/ReplayLink';

import { PreviewCard } from '../preview-effects/PreviewCard';
import { Effects, EffectsObject } from './replay-types';
import { DeletedItem, EffectsItem } from './ReplayInputArgument';

export function ReplayEffects({ effects }: { effects: Effects }) {
	const output = [];
	if ('created' in effects.effectsVersion) {
		output.push(effectsSection('Created', effects.effectsVersion.created));
	}
	if ('mutated' in effects.effectsVersion) {
		output.push(effectsSection('Mutated', effects.effectsVersion.mutated));
	}
	if ('wrapped' in effects.effectsVersion) {
		output.push(effectsSection('Wrapped', effects.effectsVersion.wrapped));
	}
	if ('unwrapped' in effects.effectsVersion) {
		output.push(effectsSection('Unwrapped', effects.effectsVersion.unwrapped));
	}
	if ('deleted' in effects.effectsVersion) {
		output.push(
			<div>
				<PreviewCard.Root className="m-2">
					<PreviewCard.Header> Deleted </PreviewCard.Header>
					<PreviewCard.Body>
						<div className="text-sm max-h-[450px] overflow-y-auto grid grid-cols-1 gap-3">
							{effects.effectsVersion.deleted.map((ref, index) => (
								<DeletedItem input={ref} key={index} />
							))}
						</div>
					</PreviewCard.Body>
				</PreviewCard.Root>
			</div>,
		);

		output.push(
			<div>
				<PreviewCard.Root className="m-2">
					<PreviewCard.Header> Dependencies </PreviewCard.Header>
					<PreviewCard.Body>
						<div className="text-sm max-h-[450px] overflow-y-auto grid grid-cols-1 gap-3">
							{effects.effectsVersion.dependencies.map((dep) => (
								<ReplayLink id={dep} text={dep} />
							))}
						</div>
					</PreviewCard.Body>
				</PreviewCard.Root>
			</div>,
		);
		return output;
	}
}

const effectsSection = (name: string, input: EffectsObject[]) => {
	return (
		<div>
			<PreviewCard.Root className="m-2">
				<PreviewCard.Header> {name} </PreviewCard.Header>
				<PreviewCard.Body>
					<div className="text-sm max-h-[450px] overflow-y-auto grid grid-cols-1 gap-3">
						{input.map((item, index) => (
							<EffectsItem input={item} key={index} />
						))}
					</div>
				</PreviewCard.Body>
			</PreviewCard.Root>
		</div>
	);
};
