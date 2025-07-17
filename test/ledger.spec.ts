import { Principal } from '@dfinity/principal';
import { resolve } from 'node:path';
import { Actor, PocketIc, createIdentity } from '@dfinity/pic';
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


describe('Only ledger', () => {
    let pic: PocketIc;
    let ledger: Actor<ICRCLedgerService>;
    let ledgerCanisterId: Principal;

    const jo = createIdentity('superSecretAlicePassword');
    const bob = createIdentity('superSecretBobPassword');
    const zoo = createIdentity('superSecretZooPassword');
  
    beforeAll(async () => {


      pic = await PocketIc.create(process.env.PIC_URL);
      await pic.setTime(new Date(Date.now()).getTime());
      // Ledger
      const ledgerfixture = await ICRCLedger(pic, jo.getPrincipal(), undefined );
      ledger = ledgerfixture.actor;
      ledgerCanisterId = ledgerfixture.canisterId;

      

    });
  
    afterAll(async () => {
      await pic.tearDown();
    });
  
    it(`Check fee`  , async () => {
      const result = await ledger.icrc1_fee();
      expect(result).toBe(10000n);
    });

    it(`Check symbol`  , async () => {
      const result = await ledger.icrc1_symbol();
      expect(result).toBe("tCOIN");
    });

    it(`Check decimals`  , async () => {
      const result = await ledger.icrc1_decimals();
      expect(result).toBe(8);
    });

    it(`Check name`  , async () => {
      const result = await ledger.icrc1_name();
      expect(result).toBe("Test Coin");
    });

    it(`Check minting account`  , async () => {
      const result = await ledger.icrc1_minting_account();
      expect(result[0].owner.toText()).toBe(jo.getPrincipal().toText());
    });

    

    it(`Check ledger transaction log`  , async () => {
        const result = await ledger.get_transactions({start: 0n, length: 100n});
        expect(result.transactions.length).toBe(0);
        expect(toState(result.log_length)).toBe("0");
        
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
      expect(toState(result)).toStrictEqual({Ok:"0"});
    });

    it(`Check Bob balance`  , async () => {
      const result = await ledger.icrc1_balance_of({owner: bob.getPrincipal(), subaccount: []});
      expect(toState(result)).toBe("100000000")
    });



    it(`Check ledger transaction log`  , async () => {
      const result = await ledger.get_transactions({start: 0n, length: 100n});
      expect(result.transactions.length).toBe(1);
      expect(toState(result.log_length)).toBe("1");
      
    });


    it(`Send 10 transactions to Bob`, async () => {
      for (let i=0; i<10; i++) {
        await ledger.icrc1_transfer({
          to: {owner: bob.getPrincipal(), subaccount:[]},
          from_subaccount: [],
          amount: 1_0000_0000n,
          fee: [],
          memo: [],
          created_at_time: [],
        });
      }
    });

    it(`Check ledger transaction log`  , async () => {
        const result = await ledger.get_transactions({start: 0n, length: 100n});
        expect(result.transactions.length).toBe(11);
        expect(toState(result.log_length)).toBe("11");
        
      });


      it(`Check proper log length`  , async () => {
        const result = await ledger.get_transactions({start: 0n, length: 1n});
        expect(result.transactions.length).toBe(1);
        expect(toState(result.log_length)).toBe("11");
        
      });

      it(`Check proper response in get_transactions`  , async () => {
        const result = await ledger.get_transactions({start: 0n, length: 0n});
        expect(result.transactions.length).toBe(0);
      
        
      });
      it(`Check proper response in get_transactions (max hit)`  , async () => {
        const result = await ledger.get_transactions({start: 0n, length: 100n});
        expect(result.transactions.length).toBe(11);
        expect(toState(result.log_length)).toBe("11");

      });

      it(`First transaction should always be mint`  , async () => {
        const result = await ledger.get_transactions({start: 0n, length: 1n});
        
        expect(result.transactions[0].kind).toBe("mint");

      });

      it(`Bob send 10 transactions to Zoo`, async () => {
        for (let i=0; i<10; i++) {
          ledger.setIdentity(bob);
          await ledger.icrc1_transfer({
            to: {owner: zoo.getPrincipal(), subaccount:[]},
            from_subaccount: [],
            amount: 1_0000_0000n,
            fee: [],
            memo: [],
            created_at_time: [],
          });
        }
      });

      it(`Fee is always inside transfers`  , async () => {
        const result = await ledger.get_transactions({start: 0n, length: 100n});
        
        let someTransfers = false
        
        for (let i=0; i<result.transactions.length; i++) {
            if (result.transactions[i].kind == "transfer") {
              expect(result.transactions[i].transfer[0].fee[0]).toBe(10000n);  
              someTransfers = true;
            }
        }
        expect(someTransfers).toBe(true);
      });

      it(`first_index is correct in leder`  , async () => {
        const result = await ledger.get_transactions({start: 5n, length: 100n});
        // First index is the first transaction in the returned 'transactions' array
        
        expect(result.first_index).toBe(5n);
      });



      it(`Test deduplication`, async () => {
        const result = await ledger.get_transactions({start: 0n, length: 100n});
        expect(result.log_length).toBe(21n);
        let created_at = BigInt(Math.round(await pic.getTime())) * 1000000n;
        for (let i=0; i<10; i++) {
          ledger.setIdentity(jo);
          let trez = await ledger.icrc1_transfer({
            to: {owner: bob.getPrincipal(), subaccount:[]},
            from_subaccount: [],
            amount: 1_0000_0000n,
            fee: [],
            memo: [[0,0,0,0,0,0,0,5]],
            created_at_time: [ created_at ], // time in nanoseconds since epoch
          });
          if (i == 0) expect(toState(trez).Ok).toBe("21");
          if (i > 0) expect(toState(trez).Err).toStrictEqual({"Duplicate": {"duplicate_of": "21"}});
        }

        const result2 = await ledger.get_transactions({start: 0n, length: 100n});
        expect(result2.log_length).toBe(22n); // Only one new transaction should be added


      });

      it(`Test deduplication - different created_at, same memo`, async () => {
        const result = await ledger.get_transactions({start: 0n, length: 100n});
        expect(result.log_length).toBe(22n);
        await passTime(1);
        let created_at = BigInt(Math.round(await pic.getTime())) * 1000000n;
        for (let i=0; i<3; i++) {
          ledger.setIdentity(jo);
          let trez = await ledger.icrc1_transfer({
            to: {owner: bob.getPrincipal(), subaccount:[]},
            from_subaccount: [],
            amount: 1_0000_0000n,
            fee: [],
            memo: [[0,0,0,0,0,0,0,5]],
            created_at_time: [ created_at ], // time in nanoseconds since epoch
          });
          if (i == 0) expect(toState(trez).Ok).toBe("22");
          if (i > 0) expect(toState(trez).Err).toStrictEqual({"Duplicate": {"duplicate_of": "22"}});
        }

        const result2 = await ledger.get_transactions({start: 0n, length: 100n});
        expect(result2.log_length).toBe(23n); // Only one new transaction should be added

      });

      it(`Test deduplication - different memo, same created_at`, async () => {
        const result = await ledger.get_transactions({start: 0n, length: 100n});
        expect(result.log_length).toBe(23n);
        await passTime(1);
        let created_at = BigInt(Math.round(await pic.getTime())) * 1000000n;
        for (let i=0; i<3; i++) {
          ledger.setIdentity(jo);
          let trez = await ledger.icrc1_transfer({
            to: {owner: bob.getPrincipal(), subaccount:[]},
            from_subaccount: [],
            amount: 1_0000_0000n,
            fee: [],
            memo: [[0,0,0,0,0,0,0,i]],
            created_at_time: [ created_at ], // time in nanoseconds since epoch
          });
          expect(toState(trez).Ok).toBeDefined();
          
        }

        const result2 = await ledger.get_transactions({start: 0n, length: 100n});
        expect(result2.log_length).toBe(26n); // Only one new transaction should be added

      });


      it(`Test deduplication - 23hour time gap`, async () => {
        const result = await ledger.get_transactions({start: 0n, length: 100n});
        expect(result.log_length).toBe(26n);
        await passTime(1);
        let created_at = BigInt(Math.round(await pic.getTime())) * 1000000n;
   
        ledger.setIdentity(jo);
        let trez = await ledger.icrc1_transfer({
          to: {owner: bob.getPrincipal(), subaccount:[]},
          from_subaccount: [],
          amount: 1_0000_0000n,
          fee: [],
          memo: [[0,0,0,0,0,0,0,123]],
          created_at_time: [ created_at ], // time in nanoseconds since epoch
        });
        expect(toState(trez).Ok).toBeDefined();
    
        await pic.advanceTime(23*60*60*1000);
        await passTime(10);

        let trez2 = await ledger.icrc1_transfer({
          to: {owner: bob.getPrincipal(), subaccount:[]},
          from_subaccount: [],
          amount: 1_0000_0000n,
          fee: [],
          memo: [[0,0,0,0,0,0,0,123]],
          created_at_time: [ created_at ], // time in nanoseconds since epoch
        });
        expect(toState(trez2).Err).toStrictEqual({"Duplicate": {"duplicate_of": "26"}});

        const result2 = await ledger.get_transactions({start: 0n, length: 100n});
        expect(result2.log_length).toBe(27n); // Only one new transaction should be added

      });

      it(`Test deduplication - more than 24hour time gap (TX WINDOW 24h)`, async () => {
        const result = await ledger.get_transactions({start: 0n, length: 100n});
        expect(result.log_length).toBe(27n);
        let created_at = BigInt(Math.round(await pic.getTime())) * 1000000n;
   
        ledger.setIdentity(jo);
        let trez = await ledger.icrc1_transfer({
          to: {owner: bob.getPrincipal(), subaccount:[]},
          from_subaccount: [],
          amount: 1_0000_0000n,
          fee: [],
          memo: [[0,0,0,0,0,0,0,123]],
          created_at_time: [ created_at ], // time in nanoseconds since epoch
        });
        expect(toState(trez).Ok).toBeDefined();
    
        
        await pic.advanceTime(25*60*60*1000);
        await passTime(1);
        

        let trez2 = await ledger.icrc1_transfer({
          to: {owner: bob.getPrincipal(), subaccount:[]},
          from_subaccount: [],
          amount: 1_0000_0000n,
          fee: [],
          memo: [[0,0,0,0,0,0,0,123]],
          created_at_time: [ created_at ], // time in nanoseconds since epoch
        });

        expect(toState(trez2).Err).toStrictEqual({ TooOld: null });

        const result2 = await ledger.get_transactions({start: 0n, length: 100n});
        expect(result2.log_length).toBe(28n); // Only one new transaction should be added

      });

    async function passTime(n:number) {
      for (let i=0; i<n; i++) {
        await pic.advanceTime(3*1000);
        await pic.tick(2);
      }
    }

});
