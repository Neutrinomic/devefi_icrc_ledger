import { Principal } from '@dfinity/principal';
import { Actor, PocketIc, createIdentity } from '@hadronous/pic';
// import { IDL } from '@dfinity/candid';
import {TestService, TestCan} from "./userCanister";

import {ICRCLedgerService, ICRCLedger} from "./ledgerCanister";

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
      expect(result).toBe(100000000000n)
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
      expect(result).toStrictEqual({Ok:1n});
    });

    it(`Check Bob balance`  , async () => {
      const result = await ledger.icrc1_balance_of({owner: bob.getPrincipal(), subaccount: []});
      expect(result).toBe(1_0000_0000n)
    });

    it(`last_indexed_tx should start at 0`, async () => {
      const result = await user.get_info();
      expect(result.last_indexed_tx).toBe(0n);
    });

    it(`Check ledger transaction log`  , async () => {
      const result = await ledger.get_transactions({start: 0n, length: 100n});
      expect(result.transactions.length).toBe(2);
      expect(result.log_length).toBe(2n);
      
    });

    it(`start and last_indexed_tx should be at 1`, async () => {
   
      await passTime(1);
    
      const result = await user.start();

      await passTime(3);
      const result2 = await user.get_info();
      expect(result2.last_indexed_tx).toBe(2n);
      
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

      await passTime(50);

      const result2 = await user.get_info();

      expect(result2.last_indexed_tx).toBe(6003n);
      
    }, 600*1000);


    it('Compare user<->ledger balances', async () => {
      let accounts = await user.accounts();
      let idx =0;
      for (let [subaccount, balance] of accounts) {
        idx++;
        if (idx % 50 != 0) continue; // check only every 50th account (to improve speed, snapshot should be enough when trying to cover all)
        let ledger_balance = await ledger.icrc1_balance_of({owner: userCanisterId, subaccount:[subaccount]});
        expect(balance).toBe(ledger_balance);
      } 
    }, 190*1000);


    it('Compare user balances to snapshot', async () => {
      let accounts = await user.accounts();
      let text_accounts = accounts.map(([subaccount, balance] : [Uint8Array, BigInt]) => [Buffer.from(subaccount).toString('hex'), balance]);
      expect(text_accounts).toMatchSnapshot()
    });

    

    async function passTime(n:number) {
      for (let i=0; i<n; i++) {
        await pic.advanceTime(3*1000);
        await pic.tick(1);
      }
    }

});
