import type { Principal } from '@dfinity/principal';
import type { ActorMethod } from '@dfinity/agent';
import type { IDL } from '@dfinity/candid';

export interface anon_class_15_1 {
  'get_errors' : ActorMethod<[], [bigint, bigint, string]>,
  'start' : ActorMethod<[], undefined>,
  'stop' : ActorMethod<[], undefined>,
}
export interface _SERVICE extends anon_class_15_1 {}
export declare const idlFactory: IDL.InterfaceFactory;
export declare const init: ({ IDL }: { IDL: IDL }) => IDL.Type[];
