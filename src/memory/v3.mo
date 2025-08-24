import Map "mo:map/Map";
import BTree "mo:stableheapbtreemap/BTree";
import MU "mo:mosup";
import V2 "v2";

module {

    public module Ledger { 

        public func new() : MU.MemShell<Mem> = MU.new<Mem>({
            reader = Reader.new();
            sender = Sender.new();
            accounts = Map.new<Blob, AccountMem>();
            var meta = null;
            var next_tx_id : Nat64 = 100;
            var observed_transfer_fees : Nat = 0;
            var observed_mint : Nat = 0;
            var observed_burn : Nat = 0;
            var observed_other_tx_fees : Nat = 0;
        });

        public type AccountMem = {
            var balance : Nat;
            var in_transit : Nat;
        };

        public type Mem = {
            reader : MU.MemShell<Reader.Mem>;
            sender : MU.MemShell<Sender.Mem>;
            accounts : Map.Map<Blob, AccountMem>;
            var meta : ?Meta;
            var next_tx_id : Nat64;
            var observed_transfer_fees : Nat;
            var observed_mint: Nat;
            var observed_burn: Nat;
            var observed_other_tx_fees : Nat;
        };

        public type Meta = {
            name : Text;
            symbol : Text;
            decimals : Nat8;
            minter : ?Account;
            fee : Nat;
            max_memo: Nat;
        };

        public func upgrade(from : MU.MemShell<V2.Ledger.Mem>) : MU.MemShell<Mem> {
            MU.upgrade(from, func(a : V2.Ledger.Mem) : Mem {
                {
                    reader = a.reader;
                    sender = a.sender;
                    accounts = a.accounts;
                    var meta = a.meta;
                    var next_tx_id = a.next_tx_id;
                    var observed_transfer_fees = 0;
                    var observed_mint = 0;
                    var observed_burn = 0;
                    var observed_other_tx_fees = 0;
                }
            });
        }

    };

    public module Reader {
        public func new() : MU.MemShell<Mem> = MU.new<Mem>({
            var last_indexed_tx = 0;
        });
        public type Mem = {
            var last_indexed_tx : Nat;
        };
    };

    public module Sender {
        public func new() : MU.MemShell<Mem> = MU.new<Mem>({
            transactions = BTree.init<Nat64, Transaction>(?16);
        });
   
        public type Transaction = {
            amount: Nat;
            to : Account;
            from_subaccount : ?Blob;
            var created_at_time : Nat64; 
            memo : Blob;
            var tries: Nat;
        };

        public type Mem = {
            transactions : BTree.BTree<Nat64, Transaction>;
        };
    };

    public type Account = { owner : Principal; subaccount : ?Blob };

}