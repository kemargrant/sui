// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

export type ReplayType = {
	effects: Effects;
	gasStatus: ReplayGasStatus;
	transactionInfo: TransactionInfo;
};

export type Effects = {
	effectsVersion: EffectsV1 | EffectsV2;
};

export type EffectsV1 = {
	status: Status;
	executedEpoch: string;
	gasUsed: GasUsed;
	modifiedAtVersions: ModifiedAtVersion[];
	sharedObjects: Reference[];
	transactionDigest: string;
	mutated: EffectsObject[];
	created: EffectsObject[];
	deleted: Reference[];
	wrapped: EffectsObject[];
	unwrapped: EffectsObject[];
	gasObject: GasObject;
	dependencies: string[];
};

export type EffectsV2 = {
	status: ExecutionStatus;
	executedEpoch: string;
	gasUsed: GasUsed;
	transactionDigest: string;
	gasObjIndex?: number;
	eventsDigest?: string;
	dependencies: string[];
	lamportVersion: number;
	changedObjects: ChangedObjects[];
	unchangedSharedObjects: UnchangedSharedObject[];
	auxDataDigest?: number;
};

export type UnchangedSharedObject = {
	objectId: string;
	unchangedSharedKind: UnchangedSharedKind;
};

export type UnchangedSharedKind = {
	ReadOnlyRoot?: VersionDigest;
	MutateDeleted?: number;
	ReadDeleted?: number;
};

export type ExecutionStatus = {
	success?: string;
	failure?: ExecutionFailure;
};

export type ExecutionFailure = {
	error: string;
	command?: number;
};

export type ChangedObjects = {
	objectId: string;
	effectsObjectChange: EffectsObjectChange;
};

export type EffectsObjectChange = {
	inputState: ObjectIn;
	outputState: ObjectOut;
	idOperation: IDOperation;
};

export type IDOperation = {
	None?: string;
	Created?: string;
	Deleted?: string;
};

export type ObjectIn = {
	NotExist?: string;
	Exist?: Exist;
};

export type ObjectOut = {
	NotExist?: string;
	ObjectWrite?: Exist;
	PackageWrite?: VersionDigest;
};

export type VersionDigest = {
	version: number;
	digest: string;
};

export type Exist = {
	Digest: string;
	owner: EffectsOwner;
};

export type GasObject = {
	owner: GasObjectOwner;
	reference: Reference;
};

export type GasObjectOwner = {
	AddressOwner: string;
};

export type Reference = {
	objectId: string;
	version: number;
	digest: string;
};

export type GasUsed = {
	computationCost: string;
	storageCost: string;
	storageRebate: string;
	nonRefundableStorageFee: string;
};

export type ModifiedAtVersion = {
	objectId: string;
	sequenceNumber: string;
};

export type EffectsObject = {
	owner: EffectsOwner;
	reference: Reference;
};

export type EffectsOwner = {
	ObjectOwner?: string;
	Shared?: Shared;
	AddressOwner?: string;
};

export type Shared = {
	initialSharedVersion: number;
};

export type Status = {
	status: string;
};

export type ReplayGasStatus = {
	V2: V2;
};

export type V2 = {
	gasStatus: V2GasStatus;
	costTable: CostTable;
	gasBudget: number;
	computationCost: number;
	charge: boolean;
	gasPrice: number;
	referenceGasPrice: number;
	storageGasPrice: number;
	perObjectStorage: Array<PerObjectStorageElement[]>;
	rebateRate: number;
	unmeteredStorageRebate: number;
	gasRoundingStep: number;
};

export type CostTable = {
	minTransactionCost: number;
	maxGasBudget: number;
	packagePublishPerByteCost: number;
	objectReadPerByteCost: number;
	storagePerByteCost: number;
	executionCostTable: ExecutionCostTableClass;
	computationBucket: ComputationBucket[];
};

export type ComputationBucket = {
	min: number;
	max: number;
	cost: number;
};

export type ExecutionCostTableClass = {
	instructionTiers: { [key: string]: number };
	stackHeightTiers: { [key: string]: number };
	stackSizeTiers: { [key: string]: number };
};

export type V2GasStatus = {
	gasModelVersion: number;
	costTable: ExecutionCostTableClass;
	gasLeft: GasLeft;
	gasPrice: number;
	initialBudget: GasLeft;
	charge: boolean;
	stackHeightHighWaterMark: number;
	stackHeightCurrent: number;
	stackHeightNextTierStart: number;
	stackHeightCurrentTierMult: number;
	stackSizeHighWaterMark: number;
	stackSizeCurrent: number;
	stackSizeNextTierStart: number;
	stackSizeCurrentTierMult: number;
	instructionsExecuted: number;
	instructionsNextTierStart: number;
	instructionsCurrentTierMult: number;
	profiler: null;
};

export type GasLeft = {
	val: number;
	phantom: null;
};

export type PerObjectStorageElement = PerObjectStorageClass | string;

export type PerObjectStorageClass = {
	storageCost: number;
	storageRebate: number;
	newSize: number;
};

export type TransactionInfo = {
	ProgrammableTransaction: ReplayProgrammableTransactions;
};

export type ReplayProgrammableTransactions = {
	inputs: ReplayInput[];
	commands: CommandWithOutput[];
};

export type CommandWithOutput = {
	command: Command;
	MRef: any[];
	RetVals: any[];
};

export type Command = {
	MoveCall: MoveCall;
	SplitCoins: [string | Argument, (string | Argument)[]];
	TransferObjects: [(string | Argument)[], string | Argument];
	MergeCoins: [string | Argument, (string | Argument)[]];
	MakeMoveVec: [any[], (string | Argument)[]];
	Publish: [number[][], string[]];
	Upgrade: [number[][], string[], string, Argument];
};

export type MoveCall = {
	package: string;
	module: string;
	function: string;
	typeArguments: any[];
	arguments: Argument[];
};

export type TransactionResults = {
	MutableReferences: any[];
	ReturnValues: any[];
};

export type MutableReference = {
	Argument: Argument;
	MoveValue: MoveValue;
};

export type MoveValue = {
	numeric?: number;
	bool?: boolean;
	vector?: MoveValue[];
	struct?: MoveStruct;
};

export type MoveStruct = {
	type: TypeArgument;
	fields: Field[];
};

export type Field = {
	Identifier: string;
	MoveValue: MoveValue;
};

export type Argument = {
	Input?: number;
	NestedResult?: number[];
	Result?: number;
};

export type ReplayInput = {
	Object?: ReplayInputObject;
	Pure?: number[];
};

export type TypeArgument = {
	struct: Struct;
};

export type Struct = {
	address: string;
	module: string;
	name: string;
	type_args: any[];
};

export type ReplayInputObject = {
	ImmOrOwnedObject?: [string, number, string]; // id, version, digest
	SharedObject?: SharedObject;
};

export type SharedObject = {
	id: string;
	initialSharedVersion: number;
	mutable: boolean;
};
