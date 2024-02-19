import { resolve } from 'node:path';
import { PocketIc } from '@hadronous/pic';
import { IDL } from '@dfinity/candid';
import { _SERVICE as TestService, idlFactory as TestIdlFactory, init } from '../../../.dfx/local/canisters/test/service.did.js';
import { Principal } from '@dfinity/principal';

const WASM_PATH = resolve(
    __dirname,
    '..',
    '..',
    '..',
    '.dfx',
    'local',
    'canisters',
    'test',
    'test.wasm',
);

export async function TestCan(pic:PocketIc, ledgerCanisterId:Principal) {
    
    const fixture = await pic.setupCanister<TestService>({
        idlFactory: TestIdlFactory,
        wasm: WASM_PATH,
        arg: IDL.encode(init({ IDL }), [{ledgerId: ledgerCanisterId}]),
    });

    return fixture;
};


export { TestService };