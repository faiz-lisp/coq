(***********************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team    *)
(* <O___,, *        INRIA-Rocquencourt  &  LRI-CNRS-Orsay              *)
(*   \VV/  *************************************************************)
(*    //   *      This file is distributed under the terms of the      *)
(*         *       GNU Lesser General Public License Version 2.1       *)
(***********************************************************************)

(* $Id$ *)

open Pp
open Util
open Pcoq
open Coqast
open Ast
open Extend

(* State of the grammar extensions *)

let (grammar_state : grammar_command list ref) = ref []

(* Interpretation of the right hand side of grammar rules *)

(* When reporting errors, we add the name of the grammar rule that failed *)
let specify_name name e =
  match e with
    | UserError(lab,strm) ->
        UserError(lab, (str"during interpretation of grammar rule " ++
                          str name ++ str"," ++ spc () ++ strm))
    | Anomaly(lab,strm) ->
        Anomaly(lab, (str"during interpretation of grammar rule " ++
                        str name ++ str"," ++ spc () ++ strm))
    | Failure s ->
        Failure("during interpretation of grammar rule "^name^", "^s)
    | e -> e

let gram_action (name, etyp) env act dloc =
  try
    let v = Ast.eval_act dloc env act in
    match etyp, v with
      | (ETast, Vast ast) -> Obj.repr ast
      | (ETastl, Vastlist astl) -> Obj.repr astl
      | _ -> grammar_type_error (dloc, "Egrammar.gram_action")
  with e ->
    let (loc, exn) =
      match e with
        | Stdpp.Exc_located (loce, lexn) -> (loce, lexn)
        | e -> (dloc, e)
    in
    Stdpp.raise_with_loc loc (specify_name name exn)

(* Translation of environments: a production
 *   [ nt1($x1) ... nti($xi) ] -> act($x1..$xi)
 * is written (with camlp4 conventions):
 *   (fun vi -> .... (fun v1 -> act(v1 .. vi) )..)
 * where v1..vi are the values generated by non-terminals nt1..nti.
 * Since the actions are executed by substituing an environment,
 * make_act builds the following closure:
 *
 *      ((fun env ->
 *          (fun vi -> 
 *             (fun env -> ...
 *           
 *                  (fun v1 ->
 *                     (fun env -> gram_action .. env act)
 *                     (($x1,v1)::env))
 *                  ...)
 *             (($xi,vi)::env)))
 *         [])
 *)

let make_act name_typ a pil =
  let act_without_arg env = Gramext.action (gram_action name_typ env a)
  and make_prod_item act_tl = function
    | (None, _) -> (* parse a non-binding item *)
        (fun env -> Gramext.action (fun _ -> act_tl env))
    | (Some p, ETast) -> (* non-terminal *)
        (fun env -> Gramext.action (fun v -> act_tl ((p, Vast v) :: env)))
    | (Some p, ETastl) -> (* non-terminal (list) *)
        (fun env -> Gramext.action (fun v -> act_tl ((p, Vastlist v) :: env)))
  in 
  (List.fold_left make_prod_item act_without_arg pil) []

(* Grammar extension command. Rules are assumed correct.
 * Type-checking of grammar rules is done during the translation of
 * ast to the type grammar_command.  We only check that the existing
 * entries have the type assumed in the grammar command (these types
 * annotations are added when type-checking the command, function
 * Extend.of_ast) *)

let check_entry_type (u,n) typ =
  match force_entry_type u n typ with
    | Ast e -> Gram.Entry.obj e
    | ListAst e -> Gram.Entry.obj e

let symbol_of_prod_item univ = function
  | Term tok -> (Gramext.Stoken tok, (None, ETast))
  | NonTerm (nt, nttyp, ovar) ->
      let eobj = check_entry_type (qualified_nterm univ nt) nttyp in
      (Gramext.Snterm eobj, (ovar, nttyp))

let make_rule univ etyp rule =
  let pil = List.map (symbol_of_prod_item univ) rule.gr_production in
  let (symbs,ntl) = List.split pil in
  let act = make_act (rule.gr_name,etyp) rule.gr_action ntl in
  (symbs, act)

(* Rules of a level are entered in reverse order, so that the first rules
   are applied before the last ones *)
let extend_entry univ (te, etyp, ass, rls) =
  let rules = List.rev (List.map (make_rule univ etyp) rls) in
  grammar_extend te None [(None, ass, rules)]

(* Defines new entries. If the entry already exists, check its type *)
let define_entry univ {ge_name=n; ge_type=typ; gl_assoc=ass; gl_rules=rls} =
  let e = force_entry_type univ n typ in
  (e,typ,ass,rls)

(* Add a bunch of grammar rules. Does not check if it is well formed *)
let extend_grammar gram =
  let univ = get_univ gram.gc_univ in
  let tl = List.map (define_entry univ) gram.gc_entries in
  List.iter (extend_entry univ) tl;
  grammar_state := gram :: !grammar_state

(* backtrack the grammar extensions *)
let remove_rule univ e rule =
  let symbs =
    List.map (fun pi -> fst (symbol_of_prod_item univ pi)) rule.gr_production
  in
  match e with
    | Ast en -> Gram.delete_rule en symbs
    | ListAst en -> Gram.delete_rule en symbs

let remove_entry univ entry =
  let e = get_entry univ entry.ge_name in
  List.iter (remove_rule univ e) entry.gl_rules
    
let remove_grammar gram =
  let univ = get_univ gram.gc_univ in
  List.iter (remove_entry univ) (List.rev gram.gc_entries)

(* Summary functions: the state of the lexer is included in that of the parser.
   Because the grammar affects the set of keywords when adding or removing
   grammar rules. *)
type frozen_t = grammar_command list * Lexer.frozen_t

let freeze () = (!grammar_state, Lexer.freeze ())

(* We compare the current state of the grammar and the state to unfreeze, 
   by computing the longest common suffixes *)
let factorize_grams l1 l2 =
  if l1 == l2 then ([], [], l1) else list_share_tails l1 l2

let number_of_entries gcl =
  List.fold_left (fun n gc -> n + (List.length gc.gc_entries)) 0 gcl

let unfreeze (grams, lex) =
  let (undo, redo, common) = factorize_grams !grammar_state grams in
  (*    List.iter remove_grammar undo;*)
  remove_grammars (number_of_entries undo);
  grammar_state := common;
  Lexer.unfreeze lex;
  List.iter extend_grammar (List.rev redo)
    
let init_grammar () =
  List.iter remove_grammar !grammar_state;
  grammar_state := []

let init () =
  Lexer.init ();
  init_grammar ()
