include "typed_fs.dfy"

module FileCursor {

  import opened Machine
  import opened ByteSlice
  import opened FsKinds
  import opened JrnlSpec

  import opened TypedFs
  import opened MemInodes

  class Cursor
  {
    const ino: Ino
    const i: MemInode
    const fs: TypedFilesys

    var off: uint64
    var bs: Bytes?

    // this doesn't include fs.Repr and i.Repr; we list those explicitly
    var Repr: set<object>

    ghost const ReprFs: set<object> := fs.Repr + i.Repr

    predicate {:opaque} ValidFs()
      reads this, ReprFs
    {
      && fs.ValidIno(ino, i)
      && |fs.data[ino]| % 4096 == 0
      && off % 4096 == 0
      && bs !in i.Repr
      && (bs != null ==> off as nat + 4096 <= |fs.data[ino]|)
    }

    predicate ValidRepr()
      reads this
    {
      Repr == if bs == null then {this} else {this, bs}
    }

    predicate {:opaque} ValidBytes()
      reads this, bs, fs
      requires fs.ValidDomains()
      requires bs != null
    {
      && |bs.data| == 4096
      && off as nat + 4096 <= |fs.data[ino]|
      && bs.data == fs.data[ino][off as nat .. off as nat + 4096]
    }

    predicate Valid()
      reads this, Repr, fs.Repr, i.Repr
    {
      && ValidRepr()
      && fs.ValidDomains()
      && ValidFs()
      && (bs != null ==> ValidBytes())
    }

    // convenience function since this is a core concept
    function contents(): seq<byte>
      reads fs
      requires fs.ValidDomains()
    {
      fs.data[ino]
    }

    predicate has_data(data: seq<byte>)
      reads this, bs
    {
      bs != null && bs.data == data
    }

    constructor(fs: TypedFilesys, ino: Ino, i: MemInode)
      requires fs.ValidIno(ino, i)
      requires |fs.data[ino]| % 4096 == 0
      ensures Valid()
      ensures this.fs == fs
      ensures this.i == i
      ensures this.ino == ino
      ensures fresh(Repr - {this})
      ensures bs == null
    {
      this.ino := ino;
      this.i := i;
      this.fs := fs;

      this.off := 0;
      this.bs := null;
      this.Repr := {this};
      new;
      reveal ValidFs();
      reveal ValidBytes();
    }

    lemma data_ok()
      requires Valid()
      requires bs != null
      ensures off as nat + 4096 <= |fs.data[ino]|
      ensures bs.data == fs.data[ino][off as nat .. off as nat + 4096]
    {
      reveal ValidFs();
      reveal ValidBytes();
    }

    method size() returns (sz: uint64)
      requires Valid()
      ensures sz as nat == |fs.data[ino]|
      ensures sz % 4096 == 0
    {
      reveal ValidFs();
      fs.inode_metadata(ino, i);
      return i.sz;
    }

    twostate predicate buffer_fresh()
      reads this
    {
      fresh(Repr - old(Repr))
    }

    method advanceTo(txn: Txn, off': uint64)
      modifies this
      requires fs.has_jrnl(txn)
      requires Valid()
      requires off' % 4096 == 0
      requires off' as nat < |fs.data[ino]|
      ensures this.off == off'
      ensures bs != null
      ensures buffer_fresh()
      ensures Valid()
    {
      if off' == off && bs != null {
        return;
      }
      reveal ValidFs();
      this.off := off';
      var blk := fs.readUnsafe(txn, ino, i, off, 4096);
      bs := blk;
      Repr := {this, bs};
      reveal ValidBytes();
    }

    method writeback(txn: Txn)
      returns (ok: bool)
      modifies ReprFs
      requires ValidRepr()
      // note that ValidFs is preserved just by not modifying this directly and modifying bs
      requires ValidFs()
      requires fs.has_jrnl(txn)
      requires bs != null && |bs.data| == 4096
      ensures fs.types_unchanged()
      ensures buffer_fresh()
      ensures ok ==>
      (reveal ValidFs();
        && Valid()
        && fs.data == old(fs.data[ino := C.splice(fs.data[ino], off as nat, bs.data)]))
    {
      reveal ValidFs();
      ok := fs.writeBlock(txn, ino, i, off, bs);
      reveal ValidBytes();
    }

    method grow(txn: Txn)
      returns (ok: bool)
      modifies Repr, ReprFs
      requires Valid()
      requires fs.has_jrnl(txn)
      requires |fs.data[ino]| + 4096 <= Inode.MAX_SZ
      ensures fs.types_unchanged()
      ensures buffer_fresh()
      ensures ok ==>
      && Valid()
      && fs.data == old(fs.data[ino := fs.data[ino] + JrnlTypes.block0])
    {
      reveal ValidFs();
      var blk := NewBytes(4096);
      assert blk.data == JrnlTypes.block0;
      fs.inode_metadata(ino, i);
      ByteFs.write_data_append(fs.data[ino], i.sz as nat, blk.data);
      ok := fs.write(txn, ino, i, i.sz, blk);
      reveal ValidBytes();
    }

  }

}
