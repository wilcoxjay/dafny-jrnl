include "../../util/marshal.i.dfy"
include "../../jrnl/jrnl.s.dfy"

// NOTE: this module, unlike the others in this development, is not intended to
// be opened
//
// NOTE: factoring out Inode to a separate file made this file much _slower_ for
// some reason
module Inode {
  import opened Machine
  import opened Collections
  import opened ByteSlice
  import opened Marshal

  datatype Inode = Mk(sz: uint64, blks: seq<uint64>)

  function method div_roundup(x: nat, k: nat): nat
    requires k >= 1
  {
    (x + (k-1)) / k
  }

  predicate Valid(i:Inode)
  {
    var blks_ := i.blks;
    // only direct blocks
    && |blks_| == 15
    && i.sz as nat <= |blks_| * 4096
    && unique(blks_[..div_roundup(i.sz as nat, 4096)])
  }

  function inode_enc(i: Inode): seq<Encodable>
  {
    [EncUInt64(i.sz)] + seq_fmap(blkno => EncUInt64(blkno), i.blks)
  }

  function enc(i: Inode): seq<byte>
  {
    seq_encode(inode_enc(i))
  }

  const zero: Inode := Mk(0, repeat(0 as uint64, 15));

  lemma zero_encoding()
    ensures Valid(zero)
    ensures repeat(0 as byte, 128) == enc(zero)
  {
    assert inode_enc(zero) == [EncUInt64(0)] + repeat(EncUInt64(0), 15);
    assert inode_enc(zero) == repeat(EncUInt64(0), 16);
    // TODO: need to assume this about little-endian encoding
    assume enc_encode(EncUInt64(0)) == repeat(0 as byte, 8);
    // TODO: prove this eventually
    assume false;
  }

  method encode_ino(i: Inode) returns (bs:Bytes)
    modifies {}
    requires Valid(i)
    ensures fresh(bs)
    ensures bs.data == enc(i)
  {
    var enc := new Encoder(128);
    enc.PutInt(i.sz);
    var k: nat := 0;
    while k < 15
      modifies enc.Repr
      invariant enc.Valid()
      invariant 0 <= k <= 15
      invariant enc.bytes_left() == 128 - ((k+1)*8)
      invariant enc.enc ==
      [EncUInt64(i.sz)] +
      seq_fmap(blkno => EncUInt64(blkno), i.blks[..k])
    {
      enc.PutInt(i.blks[k]);
      k := k + 1;
    }
    assert i.blks[..15] == i.blks;
    bs := enc.FinishComplete();
  }

  method decode_ino(bs: Bytes, ghost i: Inode) returns (i': Inode)
    modifies {}
    requires bs.Valid()
    requires Valid(i)
    requires bs.data == enc(i)
    ensures i' == i
  {
    var dec := new Decoder();
    dec.Init(bs, inode_enc(i));
    var sz := dec.GetInt(i.sz);
    assert dec.enc == seq_fmap(blkno => EncUInt64(blkno), i.blks);

    var blks: seq<uint64> := [];

    var k: nat := 0;
    while k < 15
      modifies dec
      invariant dec.Valid()
      invariant Valid(i)
      invariant 0 <= k <= 15
      invariant blks == i.blks[..k]
      invariant dec.enc == seq_fmap(blkno => EncUInt64(blkno), i.blks[k..])
    {
      var blk := dec.GetInt(i.blks[k]);
      blks := blks + [blk];
      k := k + 1;
    }
    return Mk(sz, blks);
  }
}

module Fs {
  import Inode
  import opened Machine
  import opened ByteSlice
  import opened JrnlSpec
  import opened Kinds
  import opened Marshal

  type Ino = uint64

  // disk layout, in blocks:
  //
  // 513 for the jrnl
  // 1 inode block (32 inodes)
  // 1 bitmap block
  // 4096*8 data blocks
  const NumBlocks: nat := 513 + 1 + 1 + 4096*8

  const InodeBlk: Blkno := 513
  const DataAllocBlk: Blkno := 514
  function method DataBlk(blkno: uint64): Addr
    requires blkno as nat < 4096*8
  {
    Addr(513+2+blkno, 0)
  }
  function method InodeAddr(ino: Ino): (a:Addr)
    requires ino < 32
    ensures a.off < 4096*8
  {
    Addr(InodeBlk, ino*128*8)
  }

  const fs_kinds: map<Blkno, Kind> :=
    // NOTE(tej): trigger annotation suppresses warning (there's nothing to
    // trigger on here, but also nothing is necessary)
    map blkno: Blkno {:trigger} |
      513 <= blkno as nat < NumBlocks
      :: (if blkno == InodeBlk
      then KindInode
      else if blkno == DataAllocBlk
        then KindBit
        else KindBlock) as Kind

  lemma fs_kinds_valid()
    ensures kindsValid(fs_kinds)
  {}

  datatype Option<T> = Some(x:T) | None

  class Filesys
  {

    // spec state
    ghost var data: map<Ino, seq<byte>>;

    // intermediate abstractions
    ghost var inodes: map<Ino, Inode.Inode>;
    // gives the inode that owns the block
    ghost var block_used: map<Blkno, Option<Ino>>;
    ghost var data_block: map<Blkno, seq<byte>>;

    var jrnl: Jrnl;
    var balloc: Allocator;

    static predicate blkno_ok(blkno: Blkno) { blkno < 4096*8 }

    predicate Valid_basics()
      reads this, jrnl
    {
      && jrnl.Valid()
      && jrnl.kinds == fs_kinds
    }

    static lemma blkno_bit_inbounds(jrnl: Jrnl)
      requires jrnl.Valid()
      requires jrnl.kinds == fs_kinds
      ensures forall bn :: blkno_ok(bn) ==> Addr(DataAllocBlk, bn) in jrnl.data
    {}

    predicate Valid_block_used()
      requires Valid_basics()
      reads this, jrnl
    {
      blkno_bit_inbounds(jrnl);
      && (forall bn :: blkno_ok(bn) ==> bn in block_used)
      && (forall bn | bn in block_used ::
        && blkno_ok(bn)
        && jrnl.data[Addr(DataAllocBlk, bn)] == ObjBit(block_used[bn].Some?))
    }

    predicate Valid_data_block()
      requires Valid_basics()
      reads this, jrnl
    {
      && (forall blkno :: blkno < 4096*8 ==> blkno in data_block)
      && (forall blkno | blkno in data_block ::
        && blkno < 4096*8
        && jrnl.data[DataBlk(blkno)] == ObjData(data_block[blkno]))
    }

    predicate Valid_inodes()
      requires Valid_basics()
      reads this, jrnl
    {
      && (forall ino: Ino | ino < 32 :: ino in inodes)
      && (forall ino: Ino | ino in inodes ::
        && ino < 32
        && Inode.Valid(inodes[ino])
        && jrnl.data[InodeAddr(ino)] == ObjData(Inode.enc(inodes[ino])))
    }

    predicate Valid()
      reads this, jrnl
    {
      // TODO: split this into multiple predicates, ideally opaque
      && Valid_basics()

      // NOTE(tej): this is for the real abstract state, which we're not worrying
      // about for now
      // && (forall ino: Ino | ino in data :: ino in inodes)
      // && (forall ino: Ino | ino in inodes ::
      //   && ino in data
      //   && inodes[ino].sz as nat == |data[ino]|)
      // TODO: tie Inode.Inode low-level value + block data to abstract state

      && this.Valid_block_used()
      && this.Valid_data_block()
      && this.Valid_inodes()

      // TODO: tie inode ownership to inode block lists

      && balloc.max == 4096*8
    }

    constructor(d: Disk)
      ensures Valid()
    {
      var jrnl := NewJrnl(d, fs_kinds);
      this.jrnl := jrnl;

      var balloc := NewAllocator(4096*8);
      balloc.MarkUsed(0);
      this.balloc := balloc;

      this.inodes := map ino: Ino {:trigger} | ino < 513 :: Inode.zero;
      Inode.zero_encoding();
      this.block_used := map blkno: uint64 {:trigger} |
        blkno < 4096*8 :: None;
      this.data_block := map blkno: uint64 |
        blkno < 4096*8 :: zeroObject(KindBlock).bs;
    }
  }

}
