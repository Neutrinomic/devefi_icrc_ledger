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


describe('Ledger goes down', () => {
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
    
  

    it(`Transfer from canister to Bob`, async () => {
        let resp = await user.send_to(
            {owner: bob.getPrincipal(), subaccount:[]},
            100000n
          );
    
          await passTime(2);
       

          let resp2 = await user.get_info();
          expect(toState(resp2.last_indexed_tx)).toBe("1");

          let resp3 = await ledger.get_transactions({start: 0n, length: 100n});
          expect(toState(resp3.transactions.length)).toBe(1);
    });


    it(`Stop ledger`, async () => {
      await pic.stopCanister({canisterId: ledgerCanisterId});
    });

    it(`Make sure ledger is down`, async () => {
        try {
          await ledger.get_transactions({start: 0n, length: 100n});
        } catch (e:any) {
          expect(e.message).toContain("is stopped");
        }
    });

    it(`Send transactions from canister`, async () => {
        for (let i=0; i<10; i++) {
        let resp = await user.send_to(
                {owner: bob.getPrincipal(), subaccount:[]},
                100000n
            );
        };
        await passTime(1);
        let resp2 = await user.get_info();
        
        expect(toState(resp2.pending)).toBe("10");

        // Wait for the system to retry sending the transactions
        await passTime(150);
    
       
    });

    it(`Start ledger`, async () => {
      await pic.startCanister({canisterId: ledgerCanisterId});
    });


    it(`Check if transactions have arrived`, async () => {
        await passTime(10);
        let resp = await user.get_info();
        expect(toState(resp.last_indexed_tx)).toBe("11");
        expect(toState(resp.pending)).toBe("0");
    });


    it(`Try sending more than the balance`, async () => {
        let rez = await user.send_to(
                {owner: bob.getPrincipal(), subaccount:[]},
                1_00000_0000n
            );
        expect(toState(rez).err).toStrictEqual({ "InsufficientFunds": null });
    });


    it(`Stop ledger`, async () => {
        await pic.stopCanister({canisterId: ledgerCanisterId});
      });

      it(`Send more transactions from canister`, async () => {
        for (let i=0; i<10; i++) {
        let resp = await user.send_to(
                {owner: bob.getPrincipal(), subaccount:[]},
                100000n
            );
        };
        await passTime(1);
        let resp2 = await user.get_info();
        
        expect(toState(resp2.pending)).toBe("10");

        // Wait for the system to retry sending the transactions
        await passTime(150);
    
       
    });
      

    it(`Start ledger after 25 hours (out of tx window)`, async () => {
        await pic.advanceTime(25*60*60*1000);
        await passTime(1);
        await pic.startCanister({canisterId: ledgerCanisterId});
      });

    it(`Check if transactions have arrived`, async () => {
        await passTime(10);
        let resp = await user.get_info();
        expect(toState(resp.last_indexed_tx)).toBe("21");
        expect(toState(resp.pending)).toBe("0");
    });

    async function passTime(n:number) {
      for (let i=0; i<n; i++) {
        await pic.advanceTime(3*1000);
        await pic.tick(2);
      }
    }

});
