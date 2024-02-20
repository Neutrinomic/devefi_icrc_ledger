import { Principal } from '@dfinity/principal';
import { resolve } from 'node:path';
import { Actor, PocketIc, createIdentity, generateRandomIdentity } from '@hadronous/pic';
import { IDL } from '@dfinity/candid';
import { _SERVICE as TestService, idlFactory as TestIdlFactory, init } from './build/bad1.idl.js';
import { _SERVICE as BadSpamService, idlFactory as BadSpamIdlFactory, init as badSpamInit } from './build/bad1spam.idl.js';
import { _SERVICE as BadSpam2Service, idlFactory as BadSpam2IdlFactory, init as badSpam2Init } from './build/bad1spam2.idl.js';

import { ICRCLedgerService, ICRCLedger } from "./icrc_ledger/ledgerCanister";
//@ts-ignore
import { toState } from "@infu/icblast";
// Jest can't handle multi threaded BigInts o.O That's why we use toState

const WASM_PATH = resolve(__dirname, "./build/bad1.wasm");
const WASMSPAM_PATH = resolve(__dirname, "./build/bad1spam.wasm");
const WASMSPAM2_PATH = resolve(__dirname, "./build/bad1spam2.wasm");

export async function TestCan(pic: PocketIc, ledgerCanisterId: Principal) {

  const fixture = await pic.setupCanister<TestService>({
    idlFactory: TestIdlFactory,
    wasm: WASM_PATH,
    arg: IDL.encode(init({ IDL }), [{ ledgerId: ledgerCanisterId }]),
  });

  return fixture;
};


export async function BadSpam(pic: PocketIc, userCanId: Principal) {

  const fixture = await pic.setupCanister<BadSpamService>({
    idlFactory: BadSpamIdlFactory,
    wasm: WASMSPAM_PATH,
    arg: IDL.encode(badSpamInit({ IDL }), [{ userCanId }]),
  });

  return fixture;
};

export async function BadSpam2(pic: PocketIc, userCanId: Principal) {

  const fixture = await pic.setupCanister<BadSpam2Service>({
    idlFactory: BadSpam2IdlFactory,
    wasm: WASMSPAM2_PATH,
    arg: IDL.encode(badSpam2Init({ IDL }), [{ userCanId }]),
  });

  return fixture;
};

describe('Bad pattern not using the middleware', () => {
  let pic: PocketIc;
  let user: Actor<TestService>;
  let ledger: Actor<ICRCLedgerService>;
  let badspam: Actor<BadSpamService>;
  let badspam2: Actor<BadSpam2Service>;

  let userCanisterId: Principal;
  let ledgerCanisterId: Principal;

  const jo = createIdentity('superSecretAlicePassword');
  const bob = createIdentity('superSecretBobPassword');

  beforeAll(async () => {
    // console.log(`Jo Principal: ${jo.getPrincipal().toText()}`);
    // console.log(`Bob Principal: ${bob.getPrincipal().toText()}`);

    pic = await PocketIc.create({ sns: true });

    // Ledger
    const ledgerfixture = await ICRCLedger(pic, jo.getPrincipal(), pic.getSnsSubnet()?.id);
    ledger = ledgerfixture.actor;
    ledgerCanisterId = ledgerfixture.canisterId;

    // Ledger User
    const fixture = await TestCan(pic, ledgerCanisterId);
    user = fixture.actor;
    userCanisterId = fixture.canisterId;

    // Badspam
    const fixturebad = await BadSpam(pic, userCanisterId);
    badspam = fixturebad.actor;

    const fixturebad2 = await BadSpam2(pic, userCanisterId);
    badspam2 = fixturebad2.actor;

  });

  afterAll(async () => {
    await badspam.stop();
    await badspam2.stop();
    await pic.tearDown();
  }, 1000*60);

  it(`Check (minter) balance`, async () => {
    const result = await ledger.icrc1_balance_of({ owner: jo.getPrincipal(), subaccount: [] });
    expect(toState(result)).toBe("100000000000")
  });


  it(`Bob pays`, async () => {
    let r = await makePayment(bob);
    expect(r).toEqual({ ok: null });
  });


  it("Verify PicJS can handle async calls with multiple identities", async () => {

    let re = await Promise.all(Array(100).fill(0).map(async (_,idx) => {
      let uid = createIdentity('something'+idx);
      user.setIdentity(uid);
      let whoami = await user.whoami();
      expect(whoami).toEqual(uid.getPrincipal().toText());
    }));

  });
  

  it(`Flood simultaneous pays while under load`, async () => {
    await badspam.start();
    await badspam2.start();
    await passTime(20);
    // let re = await Promise.all(Array(500).fill(0).map(async (_,idx) => {

    //   let uid = createIdentity('something'+idx);
    //   return await makePayment(uid);
    // }));

    // let called_count = await user.get_called_count();
    // expect(called_count).toBeGreaterThan(2000);
    // // check how many failed
    // console.log({called_count})
    // console.log(re)
    // let failed = re.filter(x => { return ("err" in x) }).length;
    // console.log({failed});
    // expect(failed).toBeGreaterThan(0);
    let rez = await badspam.get_errors();
    console.log(rez);
  }, 1000 * 400);

  async function makePayment(id: any) {
    ledger.setIdentity(jo); // jo is minter
    const mr = await ledger.icrc1_transfer({
      to: { owner: id.getPrincipal(), subaccount: [] },
      from_subaccount: [],
      amount: 1_0002_0000n,
      fee: [],
      memo: [],
      created_at_time: [],
    });
    expect(toState(mr)).toMatchObject({
      Ok: expect.any(String)
    });
    ledger.setIdentity(id);

    const result = await ledger.icrc2_approve({
      fee: [],
      from_subaccount: [],
      memo: [],
      created_at_time: [],
      expected_allowance: [],
      expires_at: [],
      spender: { owner: userCanisterId, subaccount: [] },
      amount: 1_0001_0000n // + fee
    });

    // Expect result.Ok to be defined
    expect(toState(result)).toMatchObject({
      Ok: expect.any(String)
    }); //could not perform remote call
    
    user.setIdentity(id);
    let payresp = await user.pay();
    
    // expect(payresp).toEqual({ ok: null });
    return payresp;
  }

  async function passTime(n:number) {
    for (let i=0; i<n; i++) {
      await pic.advanceTime(3*1000);
      await pic.tick(2);
    }
  }

});
