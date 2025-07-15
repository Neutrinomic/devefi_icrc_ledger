import { Principal } from '@dfinity/principal';
import { resolve } from 'node:path';
import { Actor, PocketIc, createIdentity } from '@dfinity/pic';
import { IDL } from '@dfinity/candid';
import { _SERVICE as TestService, idlFactory as TestIdlFactory, init } from './build/burn.idl.js';

import {ICRCLedgerService, ICRCLedger} from "./icrc_ledger/ledgerCanister";
//@ts-ignore
import {toState} from "@infu/icblast";
// Jest can't handle multi threaded BigInts o.O That's why we use toState

const WASM_PATH = resolve(__dirname, "./build/burn.wasm");

export async function TestCan(pic:PocketIc, usercan:Principal, ledgerCanisterId:Principal) {
    
    const fixture = await pic.setupCanister<TestService>({
        targetCanisterId: usercan,
        idlFactory: TestIdlFactory,
        wasm: WASM_PATH,
        arg: IDL.encode(init({ IDL }), [{ledgerId: ledgerCanisterId}]),
    });

    return fixture;
};


describe('Only ledger', () => {
    let pic: PocketIc;
    let ledger: Actor<ICRCLedgerService>;
    let ledgerCanisterId: Principal;
    let user: Actor<TestService>;
    let userCanisterId: Principal;

    const jo = createIdentity('superSecretAlicePassword');
    const bob = createIdentity('superSecretBobPassword');
    const zoo = createIdentity('superSecretZooPassword');
  
    beforeAll(async () => {


        pic = await PocketIc.create(process.env.PIC_URL);

        userCanisterId = Principal.fromText("extk7-gaaaa-aaaaq-aacda-cai");


        // Ledger
        const ledgerfixture = await ICRCLedger(pic, jo.getPrincipal(), undefined );
        ledger = ledgerfixture.actor;
        ledgerCanisterId = ledgerfixture.canisterId;


        // Ledger User
        const fixture = await TestCan(pic, userCanisterId, ledgerCanisterId);
        user = fixture.actor;

        await passTime(15);

    });
  
    afterAll(async () => {
      await pic.tearDown();
    });
  
    it(`Mint from Jo to canister`, async () => {
        ledger.setIdentity(jo);
        let resp = await ledger.icrc1_transfer({
            to: {owner: userCanisterId, subaccount:[]},
            from_subaccount: [],
            amount: 1_0000_0000n,
            fee: [],
            memo: [],
            created_at_time: [],
        });
    });
    
    it(`Check if minter is set`, async () => {
        let resp = await ledger.icrc1_minting_account();

        expect(resp[0].owner.toText()).toBe(jo.getPrincipal().toText());
    });

    it(`Check transaction log canister`, async () => {
        let resp = await user.get_info();
        expect(toState(resp.last_indexed_tx)).toBe("0");
    });

    it(`Check transaction log ledger`, async () => {
        let resp = await ledger.get_transactions({start: 0n, length: 100n});
        expect(toState(resp.transactions.length)).toBe(1);

        let tx = resp.transactions[0];
        expect(tx.kind).toBe("mint");
        expect(tx.mint[0].to.owner.toText()).toBe(userCanisterId.toText());
        expect(tx.mint[0].amount).toBe(100000000n);
    });

    it(`Transfer dust (=fee) from canister to Bob`, async () => {
        let resp = await user.send_to(
            {owner: bob.getPrincipal(), subaccount:[]},
            10000n
          );
    
          await passTime(4);
          // <= fee should be ignored
       

          let resp2 = await user.get_info();
          expect(toState(resp2.last_indexed_tx)).toBe("1");

          let resp3 = await ledger.get_transactions({start: 0n, length: 100n});
          expect(toState(resp3.transactions.length)).toBe(1);
    });

    it(`Transfer dust (<fee) from canister to Bob`, async () => {
        let resp = await user.send_to(
            {owner: bob.getPrincipal(), subaccount:[]},
            1000n
          );
    
          await passTime(4);
          // <= fee should be ignored


          let resp2 = await user.get_info();
          expect(toState(resp2.last_indexed_tx)).toBe("1");

          let resp3 = await ledger.get_transactions({start: 0n, length: 100n});
          expect(toState(resp3.transactions.length)).toBe(1);
    });

    it(`Transfer dust (fee + 1) from canister to Bob`, async () => {
        let resp = await user.send_to(
            {owner: bob.getPrincipal(), subaccount:[]},
            10001n
          );
    
          await passTime(2);
          // <= fee should be ignored
     

          let resp2 = await user.get_info();
          expect(toState(resp2.last_indexed_tx)).toBe("2"); // this should pass

          let resp3 = await ledger.get_transactions({start: 0n, length: 100n});
          expect(toState(resp3.transactions.length)).toBe(2);

          expect(resp3.transactions[1].transfer[0].amount).toBe(1n);
    });

    it(`Transfer again check created at and memo`, async () => {
        let resp = await user.send_to(
            {owner: bob.getPrincipal(), subaccount:[]},
            10001n
          );
    
          await passTime(2);
          // <= fee should be ignored
     

          let resp2 = await user.get_info();
          expect(toState(resp2.last_indexed_tx)).toBe("3"); // this should pass

          let resp3 = await ledger.get_transactions({start: 0n, length: 100n});
          expect(toState(resp3.transactions.length)).toBe(3);

          expect(resp3.transactions[2].transfer[0].amount).toBe(1n);
          expect(Array.from(resp3.transactions[2].transfer[0].memo[0])).toStrictEqual([0,0,0,0,0,0,0,2]);
          expect(resp3.transactions[2].transfer[0].created_at_time[0]).toBeDefined();
    });


    async function passTime(n:number) {
      for (let i=0; i<n; i++) {
        await pic.advanceTime(3*1000);
        await pic.tick(2);
      }
    }

});
