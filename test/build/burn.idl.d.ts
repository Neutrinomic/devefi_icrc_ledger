import type { Principal } from '@dfinity/principal';
import type { ActorMethod } from '@dfinity/agent';
import type { IDL } from '@dfinity/candid';

export interface Account {
  'owner' : Principal,
  'subaccount' : [] | [Uint8Array | number[]],
}
export interface Account__1 {
  'owner' : Principal,
  'subaccount' : [] | [Uint8Array | number[]],
}
export interface Info {
  'pending' : bigint,
  'last_indexed_tx' : bigint,
  'errors' : bigint,
  'lastTxTime' : bigint,
  'accounts' : bigint,
  'actor_principal' : Principal,
  'reader_instructions_cost' : bigint,
  'sender_instructions_cost' : bigint,
}
export interface Meta {
  'fee' : bigint,
  'decimals' : number,
  'name' : string,
  'minter' : [] | [Account__1],
  'symbol' : string,
}
export type R = { 'ok' : bigint } |
  { 'err' : SendError };
export type SendError = { 'InsufficientFunds' : null };
export interface _anon_class_14_1 {
  'accounts' : ActorMethod<[], Array<[Uint8Array | number[], bigint]>>,
  'getMeta' : ActorMethod<[], Meta>,
  'getPending' : ActorMethod<[], bigint>,
  'get_balance' : ActorMethod<[[] | [Uint8Array | number[]]], bigint>,
  'get_errors' : ActorMethod<[], Array<string>>,
  'get_info' : ActorMethod<[], Info>,
  'send_to' : ActorMethod<[Account, bigint], R>,
  'ver' : ActorMethod<[], bigint>,
}
export interface _SERVICE extends _anon_class_14_1 {}
export declare const idlFactory: IDL.InterfaceFactory;
export declare const init: ({ IDL }: { IDL: IDL }) => IDL.Type[];
