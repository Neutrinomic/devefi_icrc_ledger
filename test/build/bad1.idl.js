export const idlFactory = ({ IDL }) => {
  const R = IDL.Variant({ 'ok' : IDL.Null, 'err' : IDL.Text });
  const anon_class_14_1 = IDL.Service({
    'get_called_count' : IDL.Func([], [IDL.Nat], ['query']),
    'pay' : IDL.Func([], [R], []),
    'whoami' : IDL.Func([], [IDL.Text], ['query']),
  });
  return anon_class_14_1;
};
export const init = ({ IDL }) => {
  return [IDL.Record({ 'ledgerId' : IDL.Principal })];
};
