applyblock(f, x::Union{Block,Loop}) = typeof(x)(f(x.body))
applyblock(f, x::If) = If(f(x.t), f(x.f))
applyblock(f, x) = x

walk(x, inner, outer) = outer(applyblock(xs -> map(inner, xs), x))

postwalk(f, x) = walk(x, x -> postwalk(f, x), f)
prewalk(f, x)  = walk(f(x), x -> prewalk(f, x), identity)

# remove nops

nops(x) = prewalk(x -> applyblock(is -> filter(i -> i ≠ nop, is), x), x)

# dead code

function deadcode(x)
  prewalk(x) do x
    applyblock(x) do is
      i = findfirst(b -> b isa Branch && !b.cond, is)
      i == nothing ? is : is[1:i]
    end
  end
end

mapbranches(f, b, level = -1) = applyblock(is -> mapbranches.(f, is, level+1), b)
mapbranches(f, b::Branch, level = -1) = f(b, level)

function branches_to(b)
  result = false
  mapbranches(b) do b, l
    b.level==l && (result = true)
    b
  end
  return result
end

# After removing a block that has no branches to it, decrement all of the
# branches that point to any level above it.
function decbranches(i)
  mapbranches(i) do b, l
    b.level > l ? Branch(b.cond, b.level-1) : b
  end
end

# After adding a block increment all branches pointing to a level above it.
function incbranches(i)
  mapbranches(i) do b, l
    b.level >= l ? Branch(b.cond, b.level+1) : b
  end
end

# recover ifs

function makeifs(code)
  prewalk(code) do x
    x isa Block || return x
    i = findfirst(x -> x isa Branch, x.body)
    i != nothing && x.body[i].cond || return x
    cond = x.body[1:i-1]
    cond[end] == Op(i32, :eqz) ? pop!(cond) : push!(cond, Op(i32, :eqz))
    fixbranches = incbranches(Block(x.body[i+1:end])).body
    return Block([cond..., If(fixbranches, [])])
  end
end

# remove unused blocks
# TODO: collapse blocks with the same head

function rmblocks(code)
  prewalk(code) do x
    applyblock(x) do is
      is′ = []
      for i in is
        i isa Block && !branches_to(i) ?
          append!(is′, decbranches(i).body) :
          push!(is′, i)
      end
      is′
    end
  end
end

optimise(b::Block) = b |> deadcode |> makeifs |> rmblocks |> liveness_optimisations


using LightGraphs

liveness(code::Func, as...; ks...) = liveness(code.body.body, as...; ks...)
liveness(code::Block, as...; ks...) = liveness(code.body, as...; ks...)

function liveness_(x::Local, i, alive, branch, rig, lines, as...)
  id = get!(alive, x.id) do
    lines != nothing && push!(lines, [])
    rig isa Ref && return rig.x += 1
    add_vertex!(rig) || error()
    id = nv(rig)
    for v in values(alive)
      add_edge!(rig, id, v)
    end
    return id
  end
  lines != nothing && push!(lines[id], push!(copy(branch), i))
end

function liveness_(x::SetLocal, i, alive, branch, rig, lines, perm_alive, extra_sets)
  if haskey(alive, x.id)
    id = alive[x.id]
    if !haskey(perm_alive, x.id)
      delete!(alive, x.id)
    end
    lines != nothing && push!(lines[id], push!(copy(branch), i))
  else
    extra_sets != nothing && push!(extra_sets, push!(copy(branch), i))
  end
end

function liveness_(x::Union{Block, Loop}, i, alive, branch, branches, as... ; ks...)
  push!(branches, (copy(alive), x isa Loop))
  push!(branch, i)
  liveness(x.body, alive, branch, branches, as...; ks...)
  pop!(branch)
  pop!(branches)
end

function liveness_(x::If, i, alive, branch, as... ; ks...)
  push!(branch, i)
  a_t = copy(alive)
  liveness_(Block(x.t), 1, a_t, branch, as...; ks...)
  liveness_(Block(x.f), 2, alive, branch, as...; ks...)
  pop!(branch)
  merge!(alive, a_t)
end

function liveness_(x::Branch, code, i, alive, branch, branches, perm_alive, rig, lines; ks...)
  br = branches[end-x.level]
  x.cond ? merge!(alive, copy(br[1])) : merge!(empty!(alive), copy(br[1]))
  if !br[2] # If not branching to a loop.
    liveness(code[1:i-1], alive, branch, branches, perm_alive; rig=rig, lines=lines, ks...)
  else
    # First pass of loop to get alive set after loop.
    a_f = liveness(code[1:i-1], copy(alive), branch, branches, alive; rig=Ref{Int}(rig isa Ref ? rig.x : nv(rig)))

    a_diff = Dict(a => rig isa Ref ? rig.x += 1 : (add_vertex!(rig); nv(rig)) for (a, _) in setdiff(a_f, alive))
    merge!(alive, a_diff)
    for (a, v) in a_diff
      lines != nothing && push!(lines, [])
      rig isa Ref && continue
      for v_ in values(alive)
        v == v_ && continue
        add_edge!(rig, v, v_)
      end
    end

    # Second pass of loop using the calculated alive set.
    liveness(code[1:i-1], alive, branch, branches, copy(alive); rig=rig, lines=lines, ks...)
  end
end

# rig is the Register Interference Graph. out_neighbors(value id, rig) will give
# the ids of the values that are alive at the same time as the given value id.

# lines takes a value id and returns references to all the get/sets in the code
# so they can be updated quickly later.

# extra_sets is any encountered set where the value isn't used.

# alive is essentially a set of currently used registers, but with the id of the
# value stored.

function liveness( code::Vector{Instruction}
                 , alive::Dict{Int, Int}=Dict{Int, Int}()
                 , branch::Vector{Int}=Vector{Int}()
                 , branches::Vector{Tuple{Dict{Int,Int},Bool}}=Vector{Tuple{Dict{Int,Int},Bool}}()
                 , perm_alive::Dict{Int, Int}=Dict{Int, Int}()
                 ; rig::Union{Ref{Int}, SimpleGraph{Int}}=Ref{Int}(0)
                 , lines::Union{Void, Vector{Vector{Vector{Int}}}}=nothing
                 , extra_sets::Union{Void, Vector{Vector{Int}}}=nothing
                 )
  for i in length(code):-1:1
    x = code[i]
    if x isa Local || x isa SetLocal
      liveness_(x, i, alive, branch, rig, lines, perm_alive, extra_sets)
    elseif x isa Block || x isa Loop || x isa If
      liveness_(x, i, alive, branch, branches, perm_alive; rig=rig, lines=lines, extra_sets=extra_sets)
    elseif x isa Branch
      liveness_(x, code, i, alive, branch, branches, perm_alive, rig, lines; extra_sets=extra_sets)
      break
    end
  end
  return alive
end

get_line(code, branch) = apply_line(code, copy(branch), x->x)
set_line(code, branch, y) = apply_line(code, copy(branch), x->y)
modify_line(f, code, branch) = apply_line(code, copy(branch), f)

apply_line(i::Func, bs, f) = apply_line(i.body.body, bs, f)
apply_line(i::Union{Block, Loop}, bs, f) = apply_line(i.body, bs, f)
# apply_line(i::If, bs, f) = bs |> shift! |> b -> apply_line(getfield(i, b), bs, f)
# apply_line(i::If, bs, f) = isempty(bs) ? i : bs |> shift! |> b -> getfield(i, b) |> i -> isempty(bs) ? i : apply_line(i, bs, f)
apply_line(i::If, bs, f) = isempty(bs) ? i : bs |> shift! |> b -> apply_line(getfield(i, b), bs, f)

# apply_line(i::Vector, bs, f) = (@show bs) |> shift! |> b -> isempty(bs) ? i[b] = f(i[b]) : apply_line(i[b], bs, f)
apply_line(i::Vector, bs, f) = isempty(bs) ? i : bs |> shift! |> b -> isempty(bs) ? i[b] = f(i[b]) : apply_line(i[b], bs, f)


function allocate_registers(func::Func)
  rig = SimpleGraph{Int}()
  lines = Vector{Vector{Vector{Int}}}()
  extra_sets = Vector{Vector{Int}}()
  alive = liveness(func; rig=rig, lines=lines, extra_sets=extra_sets)

  coloring = rig != SimpleGraph() ? rig |> greedy_color : LightGraphs.coloring(0, Vector{Int}())

  length(alive) == length(func.params) || println("Not all parameters are used.")

  c_to_r = Dict(coloring.colors[v] => r for (r, v) in alive)
  i = length(c_to_r) -1
  register_colours = [haskey(c_to_r, c) ? c_to_r[c] : i+=1 for c in 1:coloring.num_colors]

  col(value_id) = register_colours[coloring.colors[value_id]]
  for v in eachindex(lines)
    for l in lines[v]
      modify_line(func, l) do s
        s isa Local ? Local(col(v)) : (s isa SetLocal ? SetLocal(s.tee, col(v)) : error())
      end
    end
  end

  # This is necessary as the register hasn't been updated and might interfere
  # with operation.
  # TODO: Drop removal, not possible in all cases. (E.g.: a conditional drop)
  isempty(extra_sets) || println("Some sets aren't used, replacing with drop (nop for tee).")
  for s in extra_sets
    modify_line(x -> x.tee ? Nop() : Drop(), func, s)
  end

  locals = func.locals[1:coloring.num_colors-length(func.params)]
  return Func(func.name, func.params, func.returns, locals, func.body)
end

using GraphLayout
function drawGraph(filename, graph)
  # Output the graph
  am = Matrix(adjacency_matrix(graph))
  loc_x, loc_y = layout_spring_adj(am)
  # draw_layout_adj(am, loc_x, loc_y, filename=filename, arrowlengthfrac=0)
  draw_layout_adj(am, loc_x, loc_y, filename=filename)
end

function liveness_optimisations(b)
  es = Vector{Vector{Int}}()
  lss = Vector{Vector{Vector{Int}}}()
  liveness(b; extra_sets=es, lines=lss);
  b = extra_sets(b, es, lss)
  b = stack_locals(b, lss)
  return nops(b)
end

function stack_locals(b)
  lines = Vector{Vector{Vector{Int}}}()
  liveness(b; lines=lines)
  return nops(stack_locals(b, lines))
end

function stack_locals(b, lines)
  filter!(lines) do ls
    (length(ls) >= 2 && get_line(b, ls[end]) isa SetLocal) || return false
    return all(e->e[1:end-1]==ls[1][1:end-1], ls)
  end
  len = typemax(Int)
  while length(lines) < len
    len = length(lines)
    filter!(lines) do l
      get, set = l[end-1:end]
      if stack_change(b, set, get) == 0
        set_line(b, set, Nop())
        modify_line(b, get) do x
          length(l) == 2 ? Nop() : SetLocal(true, x.id)
        end
        return false
      end
      return true
    end
  end
  return b
end

function extra_sets(b)
  es = Vector{Vector{Int}}()
  lss = Vector{Vector{Vector{Int}}}()
  liveness(b; extra_sets=es, lines=lss);
  return nops(extra_sets(b, es, lss))
end

# Removes sets that don't later use the value. If removing the set creates more
# useless sets, removes those too without recomputing liveness.
function extra_sets(b, es, lss)
  while length(es) > 0
    filter!(es) do s
      modify_line(x -> x.tee ? Nop() : Drop(), b, s) == Drop()
    end
    for s in es
      drop_removal(get_line(b, s[1:end-1]), s[end])
    end
    map(ls -> filter!(l -> get_line(b, l) != Nop(), ls), lss)
    es = map(first, filter(ls -> length(ls) == 1 && get_line(b, ls[1]) isa SetLocal, lss))
  end
  return b
end

# It's safe to remove a drop in most circumstances, since the stack being
# dropped from is encapsulated to the current block it shouldn't be too
# complicated either. However, if there is a branch between the drop and the
# value to be dropped being added to the stack, it is unsafe to remove and
# should be left in place.

function drop_removal(b, i)
  removals = Vector{Int}()
  drop_removal(b, Ref(i), removals) || return false
  # @show removals
  for r in removals
    b[r] = ##Nop()
      if b[r] isa SetLocal # Should only be tee_local but doesn't matter.
        SetLocal(false, b[r].id)
        # Nop()
      elseif b[r] isa Block || b[r] isa Loop || b[r] isa If
        b[r]
      #   # Check for result, remove if there is one by putting a drop before each
      #   # branch and running again. (Might get annoying around conditional
      #   # branches.) If there is no result (there should be) don't remove.
      else
        Nop()
      end
  end
  return true
end

function drop_removal(b::Vector{Instruction}, i::Ref{Int}, removals)
  removals != nothing && push!(removals, i.x)
  args_left = num_args(b[i.x])
  while args_left != 0
    op = b[i.x-=1]
    op isa Branch && return false
    res = num_res(op)
    res > args_left && return false
    remove = res <= args_left && res != 0

    # If it's a tee_local, it needs to become set_local, not be removed.
    # Similar for blocks, they will lose their result.
    rmResult = op isa SetLocal && op.tee || op isa Block && false

    if remove
      args_left -= res
      if !rmResult
        drop_removal(b, i, removals) || return false
      else
        push!(removals, i.x)
      end
    elseif !remove
      drop_removal(b, i, nothing) || return false
    end
  end
  return true
end

num_args(i::Op) = op_num_args_res[i.name][1]
num_args(i::Select) = 3
num_args(i::Union{Block, Loop, If, Nop, Const, Local}) = 0
num_args(i::Union{Convert, Global, Drop, SetLocal}) = 1

num_res(i::Op) = op_num_args_res[i.name][2]
num_res(i::Select) = 1
num_res(i::SetLocal) = i.tee ? 1 : 0
# Changes when results added
num_res(i::Union{Nop, Block, Loop, If, Drop}) = 0
num_res(i::Union{Const, Convert, Local, Global}) = 1

stack_change(i::Op) = op_num_args_res[i.name] |> t -> t[2] - t[1]
stack_change(i) = num_res(i) - num_args(i)
stack_change(i::Vector{Instruction}) = mapreduce(stack_change, +, 0, i)

# Compute the stack change between 2 lines, only possible when the the level of
# both is the same, and no branches in between.
function stack_change(code, x, y)
  x[1:end-1] == y[1:end-1] || error("Stack change across blocks currently unsupported.")
  x[end] < y[end] || error("Can't check stack change in reverse.")
  block = get_line(code, x[1:end-1])
  block = block isa Vector ? block : block.body
  return stack_change(block[x[end]+1:y[end]-1])
end

const op_num_args_res =
  Dict(
    :eqz	  =>  (1, 1),
    :eq	    =>  (2, 1),
    :ne	    =>  (2, 1),
    :lt_s	  =>  (2, 1),
    :lt_u	  =>  (2, 1),
    :gt_s	  =>  (2, 1),
    :gt_u	  =>  (2, 1),
    :le_s	  =>  (2, 1),
    :le_u	  =>  (2, 1),
    :ge_s	  =>  (2, 1),
    :ge_u	  =>  (2, 1),
    :clz    =>  (1, 1),
    :ctz    =>  (1, 1),
    :popcnt =>  (1, 1),
    :add    =>  (2, 1),
    :sub    =>  (2, 1),
    :mul    =>  (2, 1),
    :div_s  =>  (2, 1),
    :div_u  =>  (2, 1),
    :rem_s  =>  (2, 1),
    :rem_u  =>  (2, 1),
    :and    =>  (2, 1),
    :or     =>  (2, 1),
    :xor    =>  (2, 1),
    :shl    =>  (2, 1),
    :shr_s  =>  (2, 1),
    :shr_u  =>  (2, 1),
    # Check these two.
    :rotl   =>  (2, 1),
    :rotr   =>  (2, 1),

    :lt       =>  (2, 1),
    :gt       =>  (2, 1),
    :le       =>  (2, 1),
    :ge       =>  (2, 1),
    :abs      =>  (1, 1),
    :neg      =>  (1, 1),
    :ceil     =>  (1, 1),
    :floor    =>  (1, 1),
    :trunc    =>  (1, 1),
    :nearest  =>  (1, 1),
    :sqrt     =>  (1, 1),
    :div      =>  (2, 1),
    :min      =>  (2, 1),
    :max      =>  (2, 1),
    :copysign =>  (2, 1)
  )
