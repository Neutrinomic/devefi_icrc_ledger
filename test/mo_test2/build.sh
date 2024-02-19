#!/bin/sh

`mocv bin`/moc `mops sources` --idl -o ./build/main.wasm --idl ./main.mo 
didc bind ./build/main.did --target js >./build/main.idl.js
didc bind ./build/main.did --target ts >./build/main.idl.d.ts