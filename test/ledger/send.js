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


let canister_id = loadCanister("ledger");

let ledger = await local(canister_id);

let balance = await ledger.icrc1_balance_of({owner:me})
console.log(`Balance: ${balance}`)

let to_canister = "be2us-64aaa-aaaaa-qaabq-cai"; // The canister in dfx.json
let testers = 10000;
let fee = 10000;
let tx_per_each = 6; // 10 transactions per each tester
let amount = testers * fee * tx_per_each;
console.log(`Sending ${amount} to ${to_canister}`);
await ledger.icrc1_transfer({to:{owner:to_canister}, amount:amount}).then(console.log)