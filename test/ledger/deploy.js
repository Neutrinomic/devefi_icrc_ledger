import fs from "fs";
import icblast, { hashIdentity, toState, initArg } from "@infu/icblast";
import { init } from "./ledger.idl.js";
import { saveCanister, loadCanister } from "./lib.js";

let localIdentity = hashIdentity("mylocalidentity");

let me = localIdentity.getPrincipal();

let local = icblast({
  identity: localIdentity,
  local: true,
  local_host: "http://localhost:8080",
});

let aa = await local("aaaaa-aa");

let canister_id = loadCanister("ledger");
let exist = canister_id ? true : false;
// if (exist) throw "Ledger canister already exists. Can be deployed only once";

if (!canister_id) {
  let rez = await aa.provisional_create_canister_with_cycles({
    settings: {
      controllers: [me],
    },
    amount: 100000000000000,
  });

  canister_id = rez.canister_id;
  saveCanister("ledger", canister_id);
}

console.log(toState({ canister_id }));

let ledger_args = {
  Init: {
    minting_account: {
      owner: me,
    },
    fee_collector_account: { owner: me },
    transfer_fee: 10000,
    decimals: 8,
    token_symbol: "tCOIN",
    token_name: "Test Coin",
    metadata: [],
    initial_balances: [[{ owner: me }, 100000000000]],
    archive_options: {
      num_blocks_to_archive: 10000,
      trigger_threshold: 9000,
      controller_id: me,
    },
  },
};

<<<<<<< HEAD
let wasm = fs.readFileSync("./ledger_canister.wasm");
=======
let wasm = fs.readFileSync("./scripts/ledger/ledger_canister.wasm");
>>>>>>> a343f2e53735ab1c4a21c67b28e93a035febc2e3

await aa.install_code({
  arg: initArg(init, [ledger_args]),
  wasm_module: wasm,
  mode: { reinstall: null },
  canister_id,
});
<<<<<<< HEAD

console.log("DONE")
=======
>>>>>>> a343f2e53735ab1c4a21c67b28e93a035febc2e3
