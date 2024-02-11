# Testing

Note: canister_ids are hardcoded so the exact sequence should be used

Note: If the ledger wasm is too old use get_latest_wasm.js (Latest SNSW ledger).

1) Start DFX
```
dfx start --clean
```

2) Deploy ledger 

```
cd test/ledger
rm canisters.json // if starting for the first time after dfx start --clean
yarn install
node deploy.js
```

3) Deploy maker
```
dfx deploy
```

4) Start the maker trough UI (start method)

5) Send tokens (they are a mint transaction)
```
node send.js
```

6) Use maker/user.blast to try different scenarios