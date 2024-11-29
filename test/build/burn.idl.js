export const idlFactory = ({ IDL }) => {
  const Account__1 = IDL.Record({
    'owner' : IDL.Principal,
    'subaccount' : IDL.Opt(IDL.Vec(IDL.Nat8)),
  });
  const Meta = IDL.Record({
    'fee' : IDL.Nat,
    'decimals' : IDL.Nat8,
    'name' : IDL.Text,
    'minter' : IDL.Opt(Account__1),
    'symbol' : IDL.Text,
  });
  const Info = IDL.Record({
    'pending' : IDL.Nat,
    'last_indexed_tx' : IDL.Nat,
    'errors' : IDL.Nat,
    'lastTxTime' : IDL.Nat64,
    'accounts' : IDL.Nat,
    'actor_principal' : IDL.Principal,
    'reader_instructions_cost' : IDL.Nat64,
    'sender_instructions_cost' : IDL.Nat64,
  });
  const Account = IDL.Record({
    'owner' : IDL.Principal,
    'subaccount' : IDL.Opt(IDL.Vec(IDL.Nat8)),
  });
  const SendError = IDL.Variant({ 'InsufficientFunds' : IDL.Null });
  const R = IDL.Variant({ 'ok' : IDL.Nat64, 'err' : SendError });
  const _anon_class_14_1 = IDL.Service({
    'accounts' : IDL.Func(
        [],
        [IDL.Vec(IDL.Tuple(IDL.Vec(IDL.Nat8), IDL.Nat))],
        ['query'],
      ),
    'getMeta' : IDL.Func([], [Meta], ['query']),
    'getPending' : IDL.Func([], [IDL.Nat], ['query']),
    'get_balance' : IDL.Func(
        [IDL.Opt(IDL.Vec(IDL.Nat8))],
        [IDL.Nat],
        ['query'],
      ),
    'get_errors' : IDL.Func([], [IDL.Vec(IDL.Text)], ['query']),
    'get_info' : IDL.Func([], [Info], ['query']),
    'send_to' : IDL.Func([Account, IDL.Nat], [R], []),
    'ver' : IDL.Func([], [IDL.Nat], ['query']),
  });
  return _anon_class_14_1;
};
export const init = ({ IDL }) => {
  return [IDL.Record({ 'ledgerId' : IDL.Principal })];
};
