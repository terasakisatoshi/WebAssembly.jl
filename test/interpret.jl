using MacroTools: postwalk

macro pair_with_wasm(xs)
  postwalk(xs) do x
    !(x isa Expr) ? :($x, $(Symbol(x, :_wasm))) : x
  end
end

macro wast_str(wast)
  return wast |> WebAssembly.parsebrackets |> WebAssembly.parse
end

relu_ifelse(x) = ifelse(x > 0, x, 0)
relu_ifelse_wasm = wast"""
(func $#relu_Int64  (param i64) (result i64)
  (i64.const 0)
  (get_local 0)
  (get_local 0)
  (i64.const 0)
  (i64.lt_s)
  (select)
  (return))
"""

relu_ternary(x) = x > 0 ? x : 0
relu_ternary_wasm = wast"""
(func $#relu_ternary_Int64  (param i64) (result i64)
  (i64.const 0)
  (get_local 0)
  (i64.lt_s)
  (if
    (then
      (get_local 0)
      (return)))
  (i64.const 0)
  (return))
"""

relu_if_then_else = relu_ifelse
relu_if_then_else_wasm = wast"""
(func $#relu_if_then_else_Int64  (param i64) (result i64)
  (i64.const 0)
  (get_local 0)
  (i64.lt_s)
  (if
    (then
      (get_local 0))
    (else
      (i64.const 0)))
  (return))
"""

function pow(x, n)
  r = 1
  while n > 0
    r *= x
    n -= 1
  end
  return r
end
pow_wasm = wast"""
(func $#pow_Int64_Int64  (param i64) (param i64) (result i64)
  (local i64) (local i64)
  (get_local 1)
  (set_local 3)
  (i64.const 1)
  (set_local 2)
  (block
    (loop
      (i64.const 0)
      (get_local 3)
      (i64.lt_s)
      (i32.eqz)
      (br_if 1)
      (get_local 2)
      (get_local 0)
      (i64.mul)
      (set_local 2)
      (get_local 3)
      (i64.const 1)
      (i64.sub)
      (set_local 3)
      (br 0)))
  (get_local 2)
  (return))
"""

addTwo(x, y) = x + y
addTwo_wasm = wast"""
(func $addTwo (param i32) (param i32) (result i32)
  (get_local 0)
  (get_local 1)
  (i32.add))
"""

tests = @pair_with_wasm [ relu_ifelse
                        , relu_ternary
                        , relu_if_then_else
                        , pow
                        , addTwo
                        ]

fib(x) = x <= 1 ? 1 : fib(x - 1) + fib(x - 2)
this(x) = pow(x + 1, x - 1)

function rand_test_wasm(f, wasm_f, n_tests = 50, max = 100)
 for i in 1:n_tests
   args = [rand(WebAssembly.jltype(typ)) % max for typ in wasm_f.params]
   WebAssembly.interpretwasm(wasm_f, WebAssembly.emptyModuleState(), args)[1] != f(args...) && return false
 end
 return true
end

function rand_test_module(fs, m, n_tests = 50, max = 10)
  wasm_fs = interpret_module(m)
  for i in eachindex(fs)
    for j in 1:n_tests
      args = [rand(WebAssembly.jltype(typ)) % max for typ in m.funcs[i].params]
      wasm_fs[i](args...)[1] != fs[i](args...) && return false
    end
  end
  return true
end

flatten(c::Complex{Int64}) = reinterpret(UInt8, [c.re, c.im])

inflate(::Type{T}, bytes) where T <: Complex{Int64} = Complex(reinterpret(Int64, bytes)...)

@testset "Parse-Interpret" begin

relu_wasm = relu_ifelse_wast

relu_wasm_expected = Func(Symbol("#relu_Int64"), [i64], [i64], [], Block([Const(0), Local(0), Local(0), Const(0), Op(i64, :lt_s), Select(), Return()]))
@test relu_wasm.body.body == relu_wasm_expected.body.body
@test relu_wasm.params == relu_wasm_expected.params
@test relu_wasm.returns == relu_wasm_expected.returns
@test relu_wasm.name == relu_wasm_expected.name

@test rand_test_wasm(relu_ifelse, relu_wasm)

# Bulk form for functions
root = "test/wast/functions/"

for test in tests
  @test rand_test_wasm(test[1], test[2])
end

# Sort of test module parsing
m = wast"""
(module
  (func $addTwo (param i32) (param i32) (result i32)
    (get_local 0)
    (get_local 1)
    (i32.add))
  (export "addTwo" (func $addTwo)))
"""
@test m.exports == [Export(:addTwo, :addTwo, :func)]
expected_func = Func(Symbol("addTwo"), [i32, i32], [i32], [], Block([Local(0), Local(1), Op(i32, :add)]))
@test m.funcs[1].body.body == expected_func.body.body
@test m.funcs[1].params == expected_func.params
@test m.funcs[1].returns == expected_func.returns
@test m.funcs[1].name == expected_func.name

m2 = wast"""
(module
  (export "this" (func $#this_Int64))
  (export "pow" (func $#pow_Int64_Int64))
  (export "fib" (func $#fib_Int64))
  (memory 1)
  (func $#fib_Int64 (param i64) (result i64)
    (get_local 0)
    (i64.const 1)
    (i64.le_s)
    (if
      (then
        (i64.const 1)
        (return)))
    (get_local 0)
    (i64.const 1)
    (i64.sub)
    (call $#fib_Int64)
    (get_local 0)
    (i64.const 2)
    (i64.sub)
    (call $#fib_Int64)
    (i64.add)
    (return))
  (func $#this_Int64 (param i64) (result i64)
    (get_local 0)
    (i64.const 1)
    (i64.add)
    (get_local 0)
    (i64.const 1)
    (i64.sub)
    (call $#pow_Int64_Int64)
    (return))
  (func $#pow_Int64_Int64 (param i64) (param i64) (result i64)
  (local i64) (local i64)
    (get_local 1)
    (set_local 3)
    (i64.const 1)
    (set_local 2)
    (block
      (loop
        (i64.const 0)
        (get_local 3)
        (i64.lt_s)
        (i32.eqz)
        (br_if 1)
        (get_local 2)
        (get_local 0)
        (i64.mul)
        (set_local 2)
        (get_local 3)
        (i64.const 1)
        (i64.sub)
        (set_local 3)
        (br 0)))
    (get_local 2)
    (return)))
"""
@test m2.exports == [Export(:this, Symbol("#this_Int64"), :func), Export(:pow, Symbol("#pow_Int64_Int64"), :func), Export(:fib, Symbol("#fib_Int64"), :func)]
@test rand_test_module([fib, this, pow], m2)

m3 = parsewast("test/wast/modules/sum.wast")

@test m3.exports == [Export(:mem, :main, :memory), Export(:sum, :sum, :func)]
@test length(m3.data[1].data) == 65536 * 10
int_array = reinterpret(Int32, m3.data[1].data)
for i in 1:10
  int_array[i] = i
end
sum_, = interpret_module(m3)
@test sum_(0, 10)[1] == sum(int_array)
for i in 1:10000
  int_array[i] = i
end
@test sum_(0, 10000)[1] == sum(int_array)

m4 = parsewast("test/wast/modules/complex.wast")

@test m4.exports == [Export(:mem, :main, :memory), Export(:complexadd, :complexadd, :func)]
@test length(m4.data[1].data) == 65536 * 1

memory = m4.data[1].data
c1 = Complex(10,2)
c2 = Complex(5,600)
memory[1:16] = flatten(c1)
memory[17:32] = flatten(c2)

fs = interpret_module(m4)
complexadd = fs[2]

# Pointers in WASM are 0 based.
complexadd(Int32[0, 16, 32]...)

@test c1 + c2 == inflate(Complex{Int64}, memory[33:49])

end
