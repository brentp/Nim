#
#
#            Nim's Runtime Library
#        (c) Copyright 2012 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## The ``intsets`` module implements an efficient int set implemented as a
## `sparse bit set`:idx:.
## **Note**: Since Nim currently does not allow the assignment operator to
## be overloaded, ``=`` for int sets performs some rather meaningless shallow
## copy; use ``assign`` to get a deep copy.

import
  hashes, math

type
  BitScalar = int

const
  InitIntSetSize = 8         # must be a power of two!
  TrunkShift = 9
  BitsPerTrunk = 1 shl TrunkShift # needs to be a power of 2 and
                                  # divisible by 64
  TrunkMask = BitsPerTrunk - 1
  IntsPerTrunk = BitsPerTrunk div (sizeof(BitScalar) * 8)
  IntShift = 5 + ord(sizeof(BitScalar) == 8) # 5 or 6, depending on int width
  IntMask = 1 shl IntShift - 1

type
  PTrunk = ref Trunk
  Trunk = object
    next: PTrunk             # all nodes are connected with this pointer
    key: int                 # start address at bit 0
    bits: array[0..IntsPerTrunk - 1, BitScalar] # a bit vector

  TrunkSeq = seq[PTrunk]
  IntSet* = object ## an efficient set of 'int' implemented as a sparse bit set
    elems: int # only valid for small numbers
    counter, max: int
    head: PTrunk
    data: TrunkSeq
    a: array[0..33, int] # profiling shows that 34 elements are enough

{.deprecated: [TIntSet: IntSet, TTrunk: Trunk, TTrunkSeq: TrunkSeq].}

proc mustRehash(length, counter: int): bool {.inline.} =
  assert(length > counter)
  result = (length * 2 < counter * 3) or (length - counter < 4)

proc nextTry(h, maxHash: Hash): Hash {.inline.} =
  result = ((5 * h) + 1) and maxHash

proc intSetGet(t: IntSet, key: int): PTrunk =
  var h = key and t.max
  while t.data[h] != nil:
    if t.data[h].key == key:
      return t.data[h]
    h = nextTry(h, t.max)
  result = nil

proc intSetRawInsert(t: IntSet, data: var TrunkSeq, desc: PTrunk) =
  var h = desc.key and t.max
  while data[h] != nil:
    assert(data[h] != desc)
    h = nextTry(h, t.max)
  assert(data[h] == nil)
  data[h] = desc

proc intSetEnlarge(t: var IntSet) =
  var n: TrunkSeq
  var oldMax = t.max
  t.max = ((t.max + 1) * 2) - 1
  newSeq(n, t.max + 1)
  for i in countup(0, oldMax):
    if t.data[i] != nil: intSetRawInsert(t, n, t.data[i])
  swap(t.data, n)

proc intSetPut(t: var IntSet, key: int): PTrunk =
  var h = key and t.max
  while t.data[h] != nil:
    if t.data[h].key == key:
      return t.data[h]
    h = nextTry(h, t.max)
  if mustRehash(t.max + 1, t.counter): intSetEnlarge(t)
  inc(t.counter)
  h = key and t.max
  while t.data[h] != nil: h = nextTry(h, t.max)
  assert(t.data[h] == nil)
  new(result)
  result.next = t.head
  result.key = key
  t.head = result
  t.data[h] = result

proc contains*(s: IntSet, key: int): bool =
  ## returns true iff `key` is in `s`.
  if s.elems <= s.a.len:
    for i in 0..<s.elems:
      if s.a[i] == key: return true
  else:
    var t = intSetGet(s, `shr`(key, TrunkShift))
    if t != nil:
      var u = key and TrunkMask
      result = (t.bits[`shr`(u, IntShift)] and `shl`(1, u and IntMask)) != 0
    else:
      result = false

proc bitincl(s: var IntSet, key: int) {.inline.} =
  var t = intSetPut(s, `shr`(key, TrunkShift))
  var u = key and TrunkMask
  t.bits[`shr`(u, IntShift)] = t.bits[`shr`(u, IntShift)] or
      `shl`(1, u and IntMask)

proc incl*(s: var IntSet, key: int) =
  ## includes an element `key` in `s`.
  if s.elems <= s.a.len:
    for i in 0..<s.elems:
      if s.a[i] == key: return
    if s.elems < s.a.len:
      s.a[s.elems] = key
      inc s.elems
      return
    newSeq(s.data, InitIntSetSize)
    s.max = InitIntSetSize-1
    for i in 0..<s.elems:
      bitincl(s, s.a[i])
    s.elems = s.a.len + 1
    # fall through:
  bitincl(s, key)

proc exclImpl(s: var IntSet, key: int) =
  if s.elems <= s.a.len:
    for i in 0..<s.elems:
      if s.a[i] == key:
        s.a[i] = s.a[s.elems-1]
        dec s.elems
        return
  else:
    var t = intSetGet(s, `shr`(key, TrunkShift))
    if t != nil:
      var u = key and TrunkMask
      t.bits[`shr`(u, IntShift)] = t.bits[`shr`(u, IntShift)] and
          not `shl`(1, u and IntMask)

proc excl*(s: var IntSet, key: int) =
  ## excludes `key` from the set `s`.
  exclImpl(s, key)

proc missingOrExcl*(s: var IntSet, key: int) : bool =
  ## returns true if `s` does not contain `key`, otherwise
  ## `key` is removed from `s` and false is returned.
  var count = s.elems
  exclImpl(s, key)
  result = count == s.elems 

proc containsOrIncl*(s: var IntSet, key: int): bool =
  ## returns true if `s` contains `key`, otherwise `key` is included in `s`
  ## and false is returned.
  if s.elems <= s.a.len:
    for i in 0..<s.elems:
      if s.a[i] == key:
        return true
    incl(s, key)
    result = false
  else:
    var t = intSetGet(s, `shr`(key, TrunkShift))
    if t != nil:
      var u = key and TrunkMask
      result = (t.bits[`shr`(u, IntShift)] and `shl`(1, u and IntMask)) != 0
      if not result:
        t.bits[`shr`(u, IntShift)] = t.bits[`shr`(u, IntShift)] or
            `shl`(1, u and IntMask)
    else:
      incl(s, key)
      result = false

proc initIntSet*: IntSet =
  ## creates a new int set that is empty.

  #newSeq(result.data, InitIntSetSize)
  #result.max = InitIntSetSize-1
  result.data = nil
  result.max = 0
  result.counter = 0
  result.head = nil
  result.elems = 0

proc clear*(result: var IntSet) =
  #setLen(result.data, InitIntSetSize)
  #for i in 0..InitIntSetSize-1: result.data[i] = nil
  #result.max = InitIntSetSize-1
  result.data = nil
  result.max = 0
  result.counter = 0
  result.head = nil
  result.elems = 0

proc isNil*(x: IntSet): bool {.inline.} = x.head.isNil and x.elems == 0

proc assign*(dest: var IntSet, src: IntSet) =
  ## copies `src` to `dest`. `dest` does not need to be initialized by
  ## `initIntSet`.
  if src.elems <= src.a.len:
    dest.data = nil
    dest.max = 0
    dest.counter = src.counter
    dest.head = nil
    dest.elems = src.elems
    dest.a = src.a
  else:
    dest.counter = src.counter
    dest.max = src.max
    newSeq(dest.data, src.data.len)

    var it = src.head
    while it != nil:

      var h = it.key and dest.max
      while dest.data[h] != nil: h = nextTry(h, dest.max)
      assert(dest.data[h] == nil)

      var n: PTrunk
      new(n)
      n.next = dest.head
      n.key = it.key
      n.bits = it.bits
      dest.head = n
      dest.data[h] = n

      it = it.next

iterator items*(s: IntSet): int {.inline.} =
  ## iterates over any included element of `s`.
  if s.elems <= s.a.len:
    for i in 0..<s.elems:
      yield s.a[i]
  else:
    var r = s.head
    while r != nil:
      var i = 0
      while i <= high(r.bits):
        var w = r.bits[i]
        # taking a copy of r.bits[i] here is correct, because
        # modifying operations are not allowed during traversation
        var j = 0
        while w != 0:         # test all remaining bits for zero
          if (w and 1) != 0:  # the bit is set!
            yield (r.key shl TrunkShift) or (i shl IntShift +% j)
          inc(j)
          w = w shr 1
        inc(i)
      r = r.next

template dollarImpl(): untyped =
  result = "{"
  for key in items(s):
    if result.len > 1: result.add(", ")
    result.add($key)
  result.add("}")

proc `$`*(s: IntSet): string =
  ## The `$` operator for int sets.
  dollarImpl()

proc empty*(s: IntSet): bool {.inline, deprecated.} =
  ## returns true if `s` is empty. This is safe to call even before
  ## the set has been initialized with `initIntSet`. Note this never
  ## worked reliably and so is deprecated.
  result = s.counter == 0

when isMainModule:
  import sequtils, algorithm

  var x = initIntSet()
  x.incl(1)
  x.incl(2)
  x.incl(7)
  x.incl(1056)

  x.incl(1044)
  x.excl(1044) 

  assert x.containsOrIncl(888) == false
  assert 888 in x
  assert x.containsOrIncl(888) == true

  assert x.missingOrExcl(888) == false
  assert 888 notin x
  assert x.missingOrExcl(888) == true

  var xs = toSeq(items(x))
  xs.sort(cmp[int])
  assert xs == @[1, 2, 7, 1056]

  var y: IntSet
  assign(y, x)
  var ys = toSeq(items(y))
  ys.sort(cmp[int])
  assert ys == @[1, 2, 7, 1056]

  var z: IntSet
  for i in 0..1000:
    incl z, i
  for i in 0..1000:
    assert i in z

