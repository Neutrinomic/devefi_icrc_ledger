import { Principal } from '@dfinity/principal';
import { resolve } from 'node:path';
import { Actor, PocketIc, createIdentity } from '@dfinity/pic';
import { IDL } from '@dfinity/candid';
import { _SERVICE as TestService, idlFactory as TestIdlFactory, init } from './build/fastscan.idl.js';
//@ts-ignore
import { toState } from "@infu/icblast";
// Jest can't handle multi threaded BigInts o.O That's why we use toState

import { ICRCLedgerService, ICRCLedger, ICRCLedgerUpgrade } from "./icrc_ledger/ledgerCanister";

const WASM_PATH = resolve(__dirname, "./build/fastscan.wasm");
const WASM_PATH_basic = resolve(__dirname, "./build/basic.wasm");

export async function TestCan(pic: PocketIc, ledgerCanisterId: Principal) {

  const fixture = await pic.setupCanister<TestService>({
    idlFactory: TestIdlFactory,
    wasm: WASM_PATH,
    arg: IDL.encode(init({ IDL }), [{ ledgerId: ledgerCanisterId }]),
  });

  return fixture;
};


describe('Passback', () => {
  let pic: PocketIc;
  let user: Actor<TestService>;
  let ledger: Actor<ICRCLedgerService>;
  let newUser: Actor<TestService>;
  let userCanisterId: Principal;
  let ledgerCanisterId: Principal;
  let newUserCanisterId: Principal;

  const jo = createIdentity('superSecretAlicePassword');
  const bob = createIdentity('superSecretBobPassword');

  let accountsSnapshot: any;

  beforeAll(async () => {

    pic = await PocketIc.create(process.env.PIC_URL);
    // Ledger
    const ledgerfixture = await ICRCLedger(pic, jo.getPrincipal(), undefined);
    ledger = ledgerfixture.actor;
    ledgerCanisterId = ledgerfixture.canisterId;

    // Ledger User
    const fixture = await TestCan(pic, ledgerCanisterId);
    user = fixture.actor;
    userCanisterId = fixture.canisterId;

    await passTime(10);

  });

  afterAll(async () => {
    await pic.tearDown();
  });

  it(`Check if fee is correct`, async () => {
    const result = await ledger.icrc1_fee();
    expect(result).toBe(10000n);
  });

  it(`Check can balance before`, async () => {
    const result = await user.get_balance([]);
    expect(toState(result)).toBe("0")
  });

  it(`Make 10 transfers to Can`, async () => {
    ledger.setIdentity(jo);
    for (let i = 0; i < 10; i++) {
      await ledger.icrc1_transfer({
        to: { owner: userCanisterId, subaccount: [] },
        from_subaccount: [],
        amount: 1000_0000n,
        fee: [],
        memo: [],
        created_at_time: [],
      });
      await passTime(3);
      const result = await user.get_balance([]);
      expect(toState(result)).toBe(((i+1)*1000_0000).toString())
    };
    
    await passTime(3);
  }, 600*1000);




  it(`Check log length`, async () => {
    await passTime(20);
    let real = await ledger.get_transactions({ start : 0n, length : 0n });

    const result2 = await user.get_info();

    expect(result2.last_indexed_tx).toBe(real.log_length);

  }, 600*1000);


  it(`Check canister balance`, async () => {
    const result = await user.get_balance([]);
    expect(toState(result)).toBe("100000000")
  });

  var chain_length_before: bigint = 0n;
  it(`Make A lot of transfers to Can`, async () => {
    ledger.setIdentity(jo);
    
    let real = await ledger.get_transactions({ start : 0n, length : 0n });
    chain_length_before = real.log_length;

    await pic.reinstallCode({ canisterId: userCanisterId, wasm: WASM_PATH_basic, arg: IDL.encode(init({ IDL }), [{ ledgerId: ledgerCanisterId }]) });
    
    await passTime(3);

    await ledger.icrc1_transfer({
      to: { owner: userCanisterId, subaccount: [] },
      from_subaccount: [],
      amount: 100000000_0000_0000n,
      fee: [],
      memo: [],
      created_at_time: [],
    });
    await passTime(5);
    await pic.stopCanister({ canisterId: userCanisterId });
    await passTime(5);
    await pic.startCanister({ canisterId: userCanisterId });
    await passTime(5);
    await pic.stopCanister({ canisterId: userCanisterId });
    await passTime(5);
    await pic.startCanister({ canisterId: userCanisterId });
    await passTime(5);
    // Upgrade canister using ledger middleware
    await pic.stopCanister({ canisterId: userCanisterId });
    await pic.upgradeCanister({ canisterId: userCanisterId, wasm: WASM_PATH_basic, arg: IDL.encode(init({ IDL }), [{ ledgerId: ledgerCanisterId }]) });
    await pic.startCanister({ canisterId: userCanisterId });
    await passTime(2);

    // Stop start Ledger
    await pic.stopCanister({ canisterId: ledgerCanisterId });
    await passTime(5);
    await pic.startCanister({ canisterId: ledgerCanisterId });

    // Upgrade ledger 
    await pic.stopCanister({ canisterId: ledgerCanisterId });
    await ICRCLedgerUpgrade(pic, jo.getPrincipal(), ledgerCanisterId, undefined);
    await pic.startCanister({ canisterId: ledgerCanisterId });
    await passTime(2);
    // Upgrade the canister using devefi ledger middleware
    await pic.stopCanister({ canisterId: userCanisterId });
    await pic.upgradeCanister({ canisterId: userCanisterId, wasm: WASM_PATH_basic, arg: IDL.encode(init({ IDL }), [{ ledgerId: ledgerCanisterId }]) });
    await pic.startCanister({ canisterId: userCanisterId });
    await passTime(2);

    let tr = await ledger.get_transactions({ start : 0n, length : 0n });
    expect(tr.log_length).toBeLessThan(7001n);

    // Upgrade ledger 
    await pic.stopCanister({ canisterId: ledgerCanisterId });
    await ICRCLedgerUpgrade(pic, jo.getPrincipal(), ledgerCanisterId, undefined);
    await pic.startCanister({ canisterId: ledgerCanisterId });
    await pic.advanceTime(13 * 1000);

    for (let i = 0; i < 100; i++) {
      await passTime(10);
      let tr = await ledger.get_transactions({ start : 0n, length : 0n });
      if (tr.log_length >= 8011n) {
        break;
      };
    };
    
  }, 600*1000);

  it(`Check log length`, async () => {
    await passTime(110);
    let real = await ledger.get_transactions({ start : 0n, length : 0n });

    const result2 = await user.get_info();
    expect(real.log_length).toBe(8011n);
    expect(result2.pending).toBe(0n);
    expect(result2.last_indexed_tx).toBe(real.log_length);
    
    

  }, 600*1000);


  it(`Check if the sum of all balances is correct`, async () => {
    let accounts = await user.accounts();
    // order by balance
    accounts.sort((a:any, b:any) => b[0] > a[0] ? 1 : b[0] < a[0] ? -1 : 0);

    let real = await ledger.get_transactions({ start : 0n, length : 0n });

    let transactions = real.log_length - chain_length_before;
    expect(transactions).toBe(8001n);
    let sum = accounts.reduce((acc:bigint, curr) => acc + curr[1], 0n);
    let pre_sent = 1000_0000n * 10n;
    let transaction_fees = transactions * 10000n - 10000n;//mint transaction doesn't count;
    expect(sum).toBe(100000000_0000_0000n + pre_sent - transaction_fees);
  });
  

  it('Compare user balances to snapshot', async () => {
    let state = accountBalancesOnlyOrdered(toState(await user.accounts()));
    accountsSnapshot = state;
    expect(state).toMatchSnapshot("accounts")
  });


  function accountBalancesOnlyOrdered(accounts: any[]) {
    return accounts.map((a:any) => a[1]).sort((a:any, b:any) => b > a ? 1 : b < a ? -1 : 0);
  }

  it(`Reinstall canister, scan everything again and compare balances`, async () => {

      await pic.reinstallCode({ canisterId: userCanisterId, wasm: WASM_PATH, arg: IDL.encode(init({ IDL }), [{ ledgerId: ledgerCanisterId }]) });


      await passTime(100);
      
      let accounts = accountBalancesOnlyOrdered(toState(await user.accounts()));
     

      expect(accounts).toStrictEqual(accountsSnapshot);

  });



  it(`Check log length`, async () => {
    await passTime(20);
    let real = await ledger.get_transactions({ start : 0n, length : 0n });

    const result2 = await user.get_info();

    expect(result2.last_indexed_tx).toBe(real.log_length);

  }, 600*1000);


  it(`Reinstall canister, stop, upgrade, scan everything again and compare balances`, async () => {
    await pic.stopCanister({ canisterId: userCanisterId });
    await pic.reinstallCode({ canisterId: userCanisterId, wasm: WASM_PATH, arg: IDL.encode(init({ IDL }), [{ ledgerId: ledgerCanisterId }]) });
    await pic.startCanister({ canisterId: userCanisterId });

    await passTime(1);
    //upgrade ledger
    await pic.stopCanister({ canisterId: ledgerCanisterId });
    await ICRCLedgerUpgrade(pic, jo.getPrincipal(), ledgerCanisterId, undefined);
    await pic.startCanister({ canisterId: ledgerCanisterId });
    await passTime(1);
    //upgrade canister
    await pic.stopCanister({ canisterId: userCanisterId });
    await pic.upgradeCanister({ canisterId: userCanisterId, wasm: WASM_PATH, arg: IDL.encode(init({ IDL }), [{ ledgerId: ledgerCanisterId }]) });
    await pic.startCanister({ canisterId: userCanisterId });
    await passTime(1);

    // stop canister 
    await pic.stopCanister({ canisterId: userCanisterId });
    await passTime(1);
    // start canister
    await pic.startCanister({ canisterId: userCanisterId });
    await passTime(1);


    await passTime(100);
    let accounts = accountBalancesOnlyOrdered(toState(await user.accounts()));

    expect(accounts).toStrictEqual(accountsSnapshot);

});


it(`Check if the sum of all balances is correct`, async () => {
  let accounts = await user.accounts();
  // order by balance
  accounts.sort((a:any, b:any) => b[0] > a[0] ? 1 : b[0] < a[0] ? -1 : 0);

  let real = await ledger.get_transactions({ start : 0n, length : 0n });

  let transactions = real.log_length - chain_length_before;
  expect(transactions).toBe(8001n);
  let sum = accounts.reduce((acc:bigint, curr) => acc + curr[1], 0n);
  let pre_sent = 1000_0000n * 10n;
  let transaction_fees = transactions * 10000n - 10000n;//mint transaction doesn't count;
  expect(sum).toBe(100000000_0000_0000n + pre_sent - transaction_fees);
});


it(`Check log length`, async () => {
  await passTime(20);
  let real = await ledger.get_transactions({ start : 0n, length : 0n });

  const result2 = await user.get_info();
  console.log(result2);
  let errs = await user.get_errors();
  console.log(errs);
  expect(result2.last_indexed_tx).toBe(real.log_length);

}, 600*1000);

  async function passTime(n: number) {
    for (let i = 0; i < n; i++) {
      await pic.advanceTime(3 * 1000);
      await pic.tick(1);
    }
  }

});
