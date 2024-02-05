import fs from "fs";

export function saveCanister(name, canister_id) {
  let j = {};
  try {
    j = JSON.parse(fs.readFileSync("./canisters.json"));
  } catch (e) {}
  if ("toText" in canister_id) canister_id = canister_id.toText();
  j[name] = canister_id;
  fs.writeFileSync("./canisters.json", JSON.stringify(j, null, 2));
}

export function loadCanister(name) {
  let j = {};
  try {
    j = JSON.parse(fs.readFileSync("./canisters.json"));
  } catch (e) {}
  return j[name];
}
