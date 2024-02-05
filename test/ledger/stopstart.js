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

const delay = ms => new Promise(res => setTimeout(res, ms));


console.log("STOPPING")
await aa.stop_canister({
  canister_id
  })

console.log("WAITING")
  await delay(10000);

console.log("STARTING")
  await aa.start_canister({
    canister_id
    })


console.log("DONE")