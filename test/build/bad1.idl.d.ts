import type { Principal } from '@dfinity/principal';
import type { ActorMethod } from '@dfinity/agent';
import type { IDL } from '@dfinity/candid';

export type R = { 'ok' : null } |
  { 'err' : string };
export interface anon_class_14_1 {
  'get_called_count' : ActorMethod<[], bigint>,
  'pay' : ActorMethod<[], R>,
  'whoami' : ActorMethod<[], string>,
}
export interface _SERVICE extends anon_class_14_1 {}
export declare const idlFactory: IDL.InterfaceFactory;
export declare const init: ({ IDL }: { IDL: IDL }) => IDL.Type[];
