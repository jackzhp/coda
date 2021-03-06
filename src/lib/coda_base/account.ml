(* account.ml *)

[%%import
"/src/config.mlh"]

open Core_kernel

[%%ifdef
consensus_mechanism]

open Snark_params
open Tick

[%%else]

module Currency = Currency_nonconsensus.Currency
module Coda_numbers = Coda_numbers_nonconsensus.Coda_numbers
module Random_oracle = Random_oracle_nonconsensus.Random_oracle
module Coda_compile_config =
  Coda_compile_config_nonconsensus.Coda_compile_config
open Snark_params_nonconsensus

[%%endif]

open Currency
open Coda_numbers
open Fold_lib
open Import

module Index = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type t = int [@@deriving to_yojson, sexp]

      let to_latest = Fn.id
    end
  end]

  let to_int = Int.to_int

  let gen ~ledger_depth = Int.gen_incl 0 ((1 lsl ledger_depth) - 1)

  module Table = Int.Table

  module Vector = struct
    include Int

    let empty = zero

    let get t i = (t lsr i) land 1 = 1

    let set v i b = if b then v lor (one lsl i) else v land lnot (one lsl i)
  end

  let to_bits ~ledger_depth t = List.init ledger_depth ~f:(Vector.get t)

  let of_bits =
    List.foldi ~init:Vector.empty ~f:(fun i t b -> Vector.set t i b)

  let fold_bits ~ledger_depth t =
    { Fold.fold=
        (fun ~init ~f ->
          let rec go acc i =
            if i = ledger_depth then acc
            else go (f acc (Vector.get t i)) (i + 1)
          in
          go init 0 ) }

  let fold ~ledger_depth t =
    Fold.group3 ~default:false (fold_bits ~ledger_depth t)

  [%%ifdef
  consensus_mechanism]

  module Unpacked = struct
    type var = Tick.Boolean.var list

    type value = Vector.t

    let typ ~ledger_depth : (var, value) Tick.Typ.t =
      Typ.transport
        (Typ.list ~length:ledger_depth Boolean.typ)
        ~there:(to_bits ~ledger_depth) ~back:of_bits
  end

  [%%endif]
end

module Nonce = Account_nonce

module Poly = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type ( 'pk
           , 'tid
           , 'token_permissions
           , 'amount
           , 'nonce
           , 'receipt_chain_hash
           , 'delegate
           , 'state_hash
           , 'timing
           , 'snapp_opt )
           t =
        { public_key: 'pk
        ; token_id: 'tid
        ; token_permissions: 'token_permissions
        ; balance: 'amount
        ; nonce: 'nonce
        ; receipt_chain_hash: 'receipt_chain_hash
        ; delegate: 'delegate
        ; voting_for: 'state_hash
        ; timing: 'timing
        ; snapp: 'snapp_opt }
      [@@deriving sexp, eq, compare, hash, yojson, fields, hlist]
    end
  end]
end

module Key = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type t = Public_key.Compressed.Stable.V1.t
      [@@deriving sexp, eq, hash, compare, yojson]

      let to_latest = Fn.id
    end
  end]
end

module Identifier = Account_id

type key = Key.t [@@deriving sexp, eq, hash, compare, yojson]

module Timing = Account_timing

[%%versioned
module Stable = struct
  module V1 = struct
    type t =
      ( Public_key.Compressed.Stable.V1.t
      , Token_id.Stable.V1.t
      , Token_permissions.Stable.V1.t
      , Balance.Stable.V1.t
      , Nonce.Stable.V1.t
      , Receipt.Chain_hash.Stable.V1.t
      , Public_key.Compressed.Stable.V1.t option
      , State_hash.Stable.V1.t
      , Timing.Stable.V1.t
      , Snapp_account.Stable.V1.t option )
      Poly.Stable.V1.t
    [@@deriving sexp, eq, hash, compare, yojson]

    let to_latest = Fn.id

    let public_key (t : t) : key = t.public_key
  end
end]

[%%define_locally
Stable.Latest.(public_key)]

let token {Poly.token_id; _} = token_id

let identifier ({public_key; token_id; _} : t) =
  Account_id.create public_key token_id

type value =
  ( Public_key.Compressed.t
  , Token_id.t
  , Token_permissions.t
  , Balance.t
  , Nonce.t
  , Receipt.Chain_hash.t
  , Public_key.Compressed.t option
  , State_hash.t
  , Timing.t
  , Snapp_account.t option )
  Poly.t
[@@deriving sexp]

let key_gen = Public_key.Compressed.gen

let initialize ?snapp account_id : t =
  let public_key = Account_id.public_key account_id in
  let token_id = Account_id.token_id account_id in
  let delegate =
    (* Only allow delegation if this account is for the default token. *)
    if Token_id.(equal default token_id) then Some public_key else None
  in
  { public_key
  ; token_id
  ; token_permissions= Token_permissions.default
  ; balance= Balance.zero
  ; nonce= Nonce.zero
  ; receipt_chain_hash= Receipt.Chain_hash.empty
  ; delegate
  ; voting_for= State_hash.dummy
  ; timing= Timing.Untimed
  ; snapp }

let hash_snapp_account_opt = function
  | None ->
      (* TODO: Should be the hash of a real snapp account *)
      Field.zero
  | Some a ->
      Random_oracle.hash ~init:Hash_prefix_states.snapp_account
        (Random_oracle.pack_input (Snapp_account.to_input a))

let delegate_opt = Option.value ~default:Public_key.Compressed.empty

let to_input (t : t) =
  let open Random_oracle.Input in
  let f mk acc field = mk (Core_kernel.Field.get field t) :: acc in
  let bits conv = f (Fn.compose bitstring conv) in
  Poly.Fields.fold ~init:[]
    ~public_key:(f Public_key.Compressed.to_input)
    ~token_id:(f Token_id.to_input) ~balance:(bits Balance.to_bits)
    ~token_permissions:(f Token_permissions.to_input)
    ~nonce:(bits Nonce.Bits.to_bits)
    ~receipt_chain_hash:(f Receipt.Chain_hash.to_input)
    ~delegate:(f (Fn.compose Public_key.Compressed.to_input delegate_opt))
    ~voting_for:(f State_hash.to_input) ~timing:(bits Timing.to_bits)
    ~snapp:(f (Fn.compose field hash_snapp_account_opt))
  |> List.reduce_exn ~f:append

let crypto_hash_prefix = Hash_prefix.account

let crypto_hash t =
  Random_oracle.hash ~init:crypto_hash_prefix
    (Random_oracle.pack_input (to_input t))

[%%ifdef
consensus_mechanism]

type var =
  ( Public_key.Compressed.var
  , Token_id.var
  , Token_permissions.var
  , Balance.var
  , Nonce.Checked.t
  , Receipt.Chain_hash.var
  , Public_key.Compressed.var
  , State_hash.var
  , Timing.var
  , Field.Var.t )
  Poly.t

let identifier_of_var ({public_key; token_id; _} : var) =
  Account_id.Checked.create public_key token_id

let typ : (var, value) Typ.t =
  let spec =
    Data_spec.
      [ Public_key.Compressed.typ
      ; Token_id.typ
      ; Token_permissions.typ
      ; Balance.typ
      ; Nonce.typ
      ; Receipt.Chain_hash.typ
      ; Typ.transport Public_key.Compressed.typ ~there:delegate_opt
          ~back:(fun delegate ->
            if Public_key.Compressed.(equal empty) delegate then None
            else Some delegate )
      ; State_hash.typ
      ; Timing.typ
      ; Typ.transport Field.typ ~there:hash_snapp_account_opt ~back:(fun fld ->
            if Field.(equal zero) fld then None else failwith "unimplemented"
        ) ]
  in
  Typ.of_hlistable spec ~var_to_hlist:Poly.to_hlist ~var_of_hlist:Poly.of_hlist
    ~value_to_hlist:Poly.to_hlist ~value_of_hlist:Poly.of_hlist

let var_of_t
    ({ public_key
     ; token_id
     ; token_permissions
     ; balance
     ; nonce
     ; receipt_chain_hash
     ; delegate
     ; voting_for
     ; timing
     ; snapp } :
      value) =
  { Poly.public_key= Public_key.Compressed.var_of_t public_key
  ; token_id= Token_id.var_of_t token_id
  ; token_permissions= Token_permissions.var_of_t token_permissions
  ; balance= Balance.var_of_t balance
  ; nonce= Nonce.Checked.constant nonce
  ; receipt_chain_hash= Receipt.Chain_hash.var_of_t receipt_chain_hash
  ; delegate= Public_key.Compressed.var_of_t (delegate_opt delegate)
  ; voting_for= State_hash.var_of_t voting_for
  ; timing= Timing.var_of_t timing
  ; snapp= Field.Var.constant (hash_snapp_account_opt snapp) }

module Checked = struct
  let to_input (t : var) =
    let ( ! ) f x = Run.run_checked (f x) in
    let f mk acc field = mk (Core_kernel.Field.get field t) :: acc in
    let open Random_oracle.Input in
    let bits conv =
      f (fun x ->
          bitstring (Bitstring_lib.Bitstring.Lsb_first.to_list (conv x)) )
    in
    make_checked (fun () ->
        List.reduce_exn ~f:append
          (Poly.Fields.fold ~init:[] ~snapp:(f field)
             ~public_key:(f Public_key.Compressed.Checked.to_input)
             ~token_id:
               (* We use [run_checked] here to avoid routing the [Checked.t]
                  monad throughout this calculation.
               *)
               (f (fun x -> Run.run_checked (Token_id.Checked.to_input x)))
             ~token_permissions:(f Token_permissions.var_to_input)
             ~balance:(bits Balance.var_to_bits)
             ~nonce:(bits !Nonce.Checked.to_bits)
             ~receipt_chain_hash:(f Receipt.Chain_hash.var_to_input)
             ~delegate:(f Public_key.Compressed.Checked.to_input)
             ~voting_for:(f State_hash.var_to_input)
             ~timing:(bits Timing.var_to_bits)) )

  let digest t =
    make_checked (fun () ->
        Random_oracle.Checked.(
          hash ~init:crypto_hash_prefix
            (pack_input (Run.run_checked (to_input t)))) )
end

[%%endif]

let digest = crypto_hash

let empty =
  { Poly.public_key= Public_key.Compressed.empty
  ; token_id= Token_id.default
  ; token_permissions= Token_permissions.default
  ; balance= Balance.zero
  ; nonce= Nonce.zero
  ; receipt_chain_hash= Receipt.Chain_hash.empty
  ; delegate= None
  ; voting_for= State_hash.dummy
  ; timing= Timing.Untimed
  ; snapp= None }

let empty_digest = digest empty

let create account_id balance =
  let public_key = Account_id.public_key account_id in
  let token_id = Account_id.token_id account_id in
  let delegate =
    (* Only allow delegation if this account is for the default token. *)
    if Token_id.(equal default) token_id then Some public_key else None
  in
  { Poly.public_key
  ; token_id
  ; token_permissions= Token_permissions.default
  ; balance
  ; nonce= Nonce.zero
  ; receipt_chain_hash= Receipt.Chain_hash.empty
  ; delegate
  ; voting_for= State_hash.dummy
  ; timing= Timing.Untimed
  ; snapp= None }

let create_timed account_id balance ~initial_minimum_balance ~cliff_time
    ~vesting_period ~vesting_increment =
  if Balance.(initial_minimum_balance > balance) then
    Or_error.errorf
      !"Error creating timed account for account id %{sexp: Account_id.t}: \
        initial minimum balance %{sexp: Balance.t} greater than balance \
        %{sexp: Balance.t} for account "
      account_id initial_minimum_balance balance
  else if Global_slot.(equal vesting_period zero) then
    Or_error.errorf
      !"Error creating timed account for account id %{sexp: Account_id.t}: \
        vesting period must be greater than zero"
      account_id
  else
    let public_key = Account_id.public_key account_id in
    let token_id = Account_id.token_id account_id in
    let delegate =
      (* Only allow delegation if this account is for the default token. *)
      if Token_id.(equal default) token_id then Some public_key else None
    in
    Or_error.return
      { Poly.public_key
      ; token_id
      ; token_permissions= Token_permissions.default
      ; balance
      ; nonce= Nonce.zero
      ; receipt_chain_hash= Receipt.Chain_hash.empty
      ; delegate
      ; voting_for= State_hash.dummy
      ; snapp= None
      ; timing=
          Timing.Timed
            { initial_minimum_balance
            ; cliff_time
            ; vesting_period
            ; vesting_increment } }

(* no vesting after cliff time + 1 slot *)
let create_time_locked public_key balance ~initial_minimum_balance ~cliff_time
    =
  create_timed public_key balance ~initial_minimum_balance ~cliff_time
    ~vesting_period:Global_slot.(succ zero)
    ~vesting_increment:initial_minimum_balance

let gen =
  let open Quickcheck.Let_syntax in
  let%bind public_key = Public_key.Compressed.gen in
  let%bind token_id = Token_id.gen in
  let%map balance = Currency.Balance.gen in
  create (Account_id.create public_key token_id) balance

let gen_timed =
  let open Quickcheck.Let_syntax in
  let%bind public_key = Public_key.Compressed.gen in
  let%bind token_id = Token_id.gen in
  let account_id = Account_id.create public_key token_id in
  let%bind balance = Currency.Balance.gen in
  (* initial min balance <= balance *)
  let%bind min_diff_int = Int.gen_incl 0 (Balance.to_int balance) in
  let min_diff = Amount.of_int min_diff_int in
  let initial_minimum_balance =
    Option.value_exn Balance.(balance - min_diff)
  in
  let%bind cliff_time = Global_slot.gen in
  (* vesting period must be at least one to avoid division by zero *)
  let%bind vesting_period =
    Int.gen_incl 1 100 >>= Fn.compose return Global_slot.of_int
  in
  let%map vesting_increment = Amount.gen in
  create_timed account_id balance ~initial_minimum_balance ~cliff_time
    ~vesting_period ~vesting_increment
