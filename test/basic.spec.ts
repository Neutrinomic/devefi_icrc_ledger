import { Principal } from '@dfinity/principal';
import { resolve } from 'node:path';
import { Actor, PocketIc, createIdentity } from '@hadronous/pic';
import { IDL } from '@dfinity/candid';
import { _SERVICE as TestService, idlFactory as TestIdlFactory, init } from './build/basic.idl.js';

import {ICRCLedgerService, ICRCLedger} from "./icrc_ledger/ledgerCanister";
//@ts-ignore
import {toState} from "@infu/icblast";
// Jest can't handle multi threaded BigInts o.O That's why we use toState

const WASM_PATH = resolve(__dirname, "./build/basic.wasm");

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
      // console.log(`Jo Principal: ${jo.getPrincipal().toText()}`);
      // console.log(`Bob Principal: ${bob.getPrincipal().toText()}`);

      pic = await PocketIc.create({sns:true});
  
      // Ledger
      const ledgerfixture = await ICRCLedger(pic, jo.getPrincipal(), pic.getSnsSubnet()?.id);
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
      const result = await ledger.icrc1_balance_of({owner: bob.getPrincipal(), subaccount: []});
      expect(toState(result)).toBe("100000000")
    });

    it(`last_indexed_tx should start at 0`, async () => {
      const result = await user.get_info();
      expect(toState(result.last_indexed_tx)).toBe("0");
    });

    it(`Check ledger transaction log`  , async () => {
      const result = await ledger.get_transactions({start: 0n, length: 100n});
      expect(result.transactions.length).toBe(2);
      expect(toState(result.log_length)).toBe("2");
      
    });

    it(`start and last_indexed_tx should be at 1`, async () => {
   
      await passTime(1);
    
      const result = await user.start();

      await passTime(3);
      const result2 = await user.get_info();
      expect(toState(result2.last_indexed_tx)).toBe("2");
      
    });

    it(`feed ledger user and check if it made the transactions`, async () => {
   
      const result = await ledger.icrc1_transfer({
        to: {owner: userCanisterId, subaccount:[]},
        from_subaccount: [],
        amount: 1000000_0000_0000n,
        fee: [],
        memo: [],
        created_at_time: [],
      });

      await passTime(120);

      const result2 = await user.get_info();

      expect(toState(result2.last_indexed_tx)).toBe("6003");
      
    }, 600*1000);


    it('Compare user<->ledger balances', async () => {
      let accounts = await user.accounts();
      let idx =0;
      for (let [subaccount, balance] of accounts) {
        idx++;
        if (idx % 50 != 0) continue; // check only every 50th account (to improve speed, snapshot should be enough when trying to cover all)
        let ledger_balance = await ledger.icrc1_balance_of({owner: userCanisterId, subaccount:[subaccount]});
        expect(toState(balance)).toBe(toState(ledger_balance));
      } 
    }, 190*1000);


    it('Compare user balances to snapshot', async () => {
      let accounts = await user.accounts();
      expect(toState(accounts)).toMatchSnapshot()
    });

    
    it('Check if error log is empty', async () => {
      let errs = await user.get_errors();
      expect(toState(errs)).toStrictEqual([]);
    });

    async function passTime(n:number) {
      for (let i=0; i<n; i++) {
        await pic.advanceTime(3*1000);
        await pic.tick(2);
      }
    }

});
