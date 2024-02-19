import { Principal } from '@dfinity/principal';
import { resolve } from 'node:path';
import { Actor, PocketIc, createIdentity } from '@hadronous/pic';
import { IDL } from '@dfinity/candid';
import { _SERVICE as TestService, idlFactory as TestIdlFactory, init } from './build/passback.idl.js';
//@ts-ignore
import {toState} from "@infu/icblast";
// Jest can't handle multi threaded BigInts o.O That's why we use toState

import {ICRCLedgerService, ICRCLedger} from "./icrc_ledger/ledgerCanister";

const WASM_PATH = resolve(__dirname, "./build/passback.wasm");

export async function TestCan(pic:PocketIc, ledgerCanisterId:Principal) {
    
    const fixture = await pic.setupCanister<TestService>({
        idlFactory: TestIdlFactory,
        wasm: WASM_PATH,
        arg: IDL.encode(init({ IDL }), [{ledgerId: ledgerCanisterId}]),
    });

    return fixture;
};


describe('Counter', () => {
    let pic: PocketIc;
    let user: Actor<TestService>;
    let ledger: Actor<ICRCLedgerService>;
    let userCanisterId: Principal;
    let ledgerCanisterId: Principal;

    const jo = createIdentity('superSecretAlicePassword');
    const bob = createIdentity('superSecretBobPassword');
  
    beforeAll(async () => {

      pic = await PocketIc.create();
      // Ledger
      const ledgerfixture = await ICRCLedger(pic, jo.getPrincipal());
      ledger = ledgerfixture.actor;
      ledgerCanisterId = ledgerfixture.canisterId;
      
      // Ledger User
      const fixture = await TestCan(pic, ledgerCanisterId);
      user = fixture.actor;
      userCanisterId = fixture.canisterId;


    });
  
    afterAll(async () => {
      await pic.tearDown();
    });
  
    it(`Check (minter) balance`  , async () => {
      const result = await ledger.icrc1_balance_of({owner: jo.getPrincipal(), subaccount: []});
      expect(toState(result)).toBe("100000000000")
    });

    it(`Send 1 to Bob`, async () => {
      ledger.setIdentity(jo);
      const result = await ledger.icrc1_transfer({
        to: {owner: bob.getPrincipal(), subaccount:[]},
        from_subaccount: [],
        amount: 1_0000_0000n,
        fee: [],
        memo: [],
        created_at_time: [],
      });
      expect(toState(result)).toStrictEqual({Ok:"1"});
    });

    it(`Check Bob balance`  , async () => {
      ledger.setIdentity(bob);
      const result = await ledger.icrc1_balance_of({owner: bob.getPrincipal(), subaccount: []});
      expect(toState(result)).toBe("100000000")
    });


    it(`Start passback`, async () => {
   
      await passTime(1);
    
      await user.start();

      await passTime(3);

      const result2 = await user.get_info();

      expect(toState(result2.last_indexed_tx)).toBe("2"); 
      
    });

    it(`Bob sends to passback`, async () => {
      ledger.setIdentity(bob);
      const result = await ledger.icrc1_transfer({
        to: {owner: userCanisterId, subaccount:[]},
        from_subaccount: [],
        amount: 5000_0000n,
        fee: [],
        memo: [],
        created_at_time: [],
      });
      expect(toState(result)).toStrictEqual({Ok:"2"});
    });

    it(`Check Bob balance before passback reacts`  , async () => {
      const result = await ledger.icrc1_balance_of({owner: bob.getPrincipal(), subaccount: []});
      expect(toState(result)).toBe("49990000")
    });


    it(`Check Bob balance after passback reacts`  , async () => {
      await passTime(3);
      const result = await ledger.icrc1_balance_of({owner: bob.getPrincipal(), subaccount: []});
      expect(toState(result)).toBe("99980000")
    });
    

    async function passTime(n:number) {
      for (let i=0; i<n; i++) {
        await pic.advanceTime(3*1000);
        await pic.tick(1);
      }
    }

});
