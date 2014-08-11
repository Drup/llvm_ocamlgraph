let id x = x

module Misc = struct

  let is_terminator llv =
    let open Llvm.ValueKind in
    let open Llvm.Opcode in
    match Llvm.classify_value llv with
      | Instruction (Br | IndirectBr | Invoke | Resume | Ret | Switch | Unreachable)
        -> true
      | _ -> false

  let basicblock_in_function llb llf =
    Llvm.block_parent llb = llf

end

open Misc

module G = struct

  (** Raise Invalid_argument if the basic block is not part of the graph. *)
  let check_block g b =
    if basicblock_in_function b g then ()
    else raise @@
      Invalid_argument
        "Llvmgraph: This basic block doesn't belong to this function."


  type t = Llvm.llvalue

  module V = struct
    type t = Llvm.llbasicblock

    (* COMPARABLE *)
    let compare = compare
    let hash = Hashtbl.hash
    let equal = (==)

    (* LABELED *)
    type label = t
    let create = id
    let label = id
  end

  type vertex = V.t

  module E
  : Graph.Sig.EDGE with type vertex = vertex and type label = unit
  = struct
    type t = V.t * V.t
    let compare = compare

    type vertex = V.t

    let src = fst
    let dst = snd

    type label = unit
    let create x () y = (x,y)
    let label _ = ()

  end
  type edge = E.t

  let is_directed = true

  (** {2 Size functions} *)

  let is_empty x = [||] = Llvm.basic_blocks x
  let nb_vertex x = Array.length @@ Llvm.basic_blocks x

  (** We will implement all other primitives though folding on
      successor or predecessor edges. *)

  let fold_succ_e f g v z =
    check_block g v ;
    match Llvm.block_terminator v with
      | None -> z
      | Some t ->
          let n = Llvm.num_operands t in
          let rec aux i acc =
            if i < n then acc
            else begin
              let o = Llvm.operand t i in
              if Llvm.value_is_block o then
                let e = E.create v () (Llvm.block_of_value o) in
                aux (i+1) @@ f e acc
              else aux (i+1) acc
            end
          in aux 0 z

  let fold_pred_e f g v z =
    check_block g v ;
    let llv = Llvm.value_of_block v in
    let aux acc llu =
      let lli = Llvm.user llu in
      let llb' = Llvm.instr_parent lli in
      if is_terminator lli
      then f (E.create v () llb') acc
      else acc
    in
    Llvm.fold_left_uses aux z llv


  (** {2 Successors and predecessors} *)

  let succ g v = fold_succ_e (fun e l -> E.dst e :: l) g v []
  let pred g v = fold_pred_e (fun e l -> E.src e :: l) g v []

  let succ_e g v = fold_succ_e (fun e l -> e :: l) g v []
  let pred_e g v = fold_pred_e (fun e l -> e :: l) g v []


  (** Degree of a vertex *)

  let out_degree g v = fold_succ_e (fun _ n -> n + 1) g v 0
  let in_degree  g v = fold_pred_e (fun _ n -> n + 1) g v 0

  (** {2 Membership functions} *)

  let mem_vertex g v = basicblock_in_function v g
  let mem_edge g v1 v2 =
    basicblock_in_function v1 g &&
    List.mem v2 @@ succ g v1

  let mem_edge_e g e = mem_edge g (E.src e) (E.dst e)

  let find_edge g v1 v2 =
    let dest = List.find (V.equal v2) @@ succ g v1 in
    E.create v1 () dest

  let find_all_edges g v1 v2 =
    List.filter (fun e -> V.equal v2 @@ E.dst e) @@ succ_e g v2

  (** {2 Graph iterators} *)

  let iter_vertex = Llvm.iter_blocks

  let fold_vertex f g z =
    Llvm.fold_left_blocks
      (fun g v -> f v g) z g

  (** {2 Edge iterators} *)

  let iter_succ_e f g v = fold_succ_e (fun e () -> f e) g v ()
  let iter_pred_e f g v = fold_pred_e (fun e () -> f e) g v ()

  (** {2 Vertex iterators} *)

  let fold_succ f g v z = fold_succ_e (fun e acc -> f (E.dst e) acc) g v z
  let fold_pred f g v z = fold_pred_e (fun e acc -> f (E.src e) acc) g v z

  let iter_succ f g v = fold_succ (fun v () -> f v) g v ()
  let iter_pred f g v = fold_pred (fun v () -> f v) g v ()

  (** {2 Iteration on all edges} *)
  (* Implemented by iteration on the successors of each node. *)

  let fold_edges_e f g z =
    fold_vertex (fun v acc -> fold_succ_e f g v acc) g z

  let fold_edges f g z = fold_edges_e (fun e acc -> f (E.src e) (E.dst e) acc) g z

  let iter_edges_e f g = fold_edges_e (fun v () -> f v) g ()
  let iter_edges f g = fold_edges (fun v v' () -> f v v') g ()

  let nb_edges g = fold_edges_e (fun _ n -> n + 1) g 0


  (** Can't implement vertex mapping. *)
  let map_vertex f g = failwith "map_vertex: Not implemented"

end

module Map (B : Graph.Builder.S) = struct

  let map ~vertex ~label g =
    let h = Hashtbl.create 128 in
    let f_add_vertex llb g =
      let v = vertex llb in
      Hashtbl.add h llb v ;
      B.add_vertex g v
    in
    let f_add_edges llb new_g =
      let aux e new_g =
        let lbl = label e in
        let src = G.E.src e in
        let dst = G.E.dst e in
        B.add_edge_e new_g
          (B.G.E.create (Hashtbl.find h src) lbl (Hashtbl.find h dst))
      in G.fold_succ_e aux g llb new_g
    in
    let new_g =
      B.empty ()
      |> G.fold_vertex f_add_vertex g
      |> G.fold_vertex f_add_edges g
    in
    Hashtbl.find h, new_g

end
