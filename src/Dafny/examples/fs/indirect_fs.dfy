include "fs.dfy"

module IndFs
{
  import opened Machine
  import opened ByteSlice
  import opened FsKinds
  import opened JrnlSpec
  import opened Fs
  import opened Marshal
  import C = Collections

  datatype IndBlock = IndBlock(bn: Blkno, blknos: seq<Blkno>)
  {
    predicate Valid()
    {
      && blkno_ok(bn)
      && |blknos| == 512
      && (forall k: int | 0 <= k < 512 :: blkno_ok(blknos[k]))
    }

    // helps state uniqueness (not just over this IndBlock but all blocks
    // involved in an inode)
    function all_blknos(): seq<Blkno>
    {
      [bn] + blknos
    }

    predicate in_fs(fs: Filesys)
      reads fs.Repr()
      requires fs.Valid()
      requires Valid()
    {
      var b := zero_lookup(fs.data_block, this.bn);
      && block_has_blknos(b, this.blknos)
    }
  }

  predicate block_has_blknos(b: Block, blknos: seq<Blkno>)
  {
    && is_block(b)
    && b == seq_enc_uint64(blknos)
    && |blknos| == 512
  }

  // there are two redundant length expressions in block_has_blknos, we can use
  // either of them to prove block_has_blknos
  lemma block_has_blknos_len(b: Block, blknos: seq<Blkno>)
    requires b == seq_enc_uint64(blknos)
    requires is_block(b) || |blknos| == 512
    ensures block_has_blknos(b, blknos)
  {
    enc_uint64_len(blknos);
    assert 4096 == 512*8;
  }

  lemma zero_block_blknos()
    ensures block_has_blknos(block0, C.repeat(0 as Blkno, 512))
  {
    zero_encode_seq_uint64(512);
  }

  method encode_blknos(blknos: seq<Blkno>) returns (bs: Bytes)
    requires |blknos| == 512
    ensures fresh(bs)
    ensures block_has_blknos(bs.data, blknos)
  {
    var enc := new Encoder(4096);
    enc.PutInts(blknos);
    assert enc.enc == C.seq_fmap(encUInt64, blknos);
    enc.is_complete();
    bs := enc.Finish();
    return;
  }

  method decode_blknos(bs: Bytes, ghost blknos: seq<Blkno>) returns (blknos': seq<Blkno>)
    requires block_has_blknos(bs.data, blknos)
    ensures blknos' == blknos
  {
    var dec := new Decoder.Init(bs, C.seq_fmap(encUInt64, blknos));
    assert dec.enc[..512] == dec.enc;
    blknos' := dec.GetInts(512, blknos);
    return;
  }


  datatype IndInodeData = IndInodeData(sz: nat, blks: seq<Block>)
  {
  }

  class IndFilesys
  {
    ghost var ind_blocks: map<Blkno, IndBlock>
    const fs: Filesys

    predicate Valid()
      reads fs.Repr()
    {
      && fs.Valid()
    }

    constructor(fs: Filesys)
      requires fs.Valid()
      ensures Valid()
    {
      this.fs := fs;
    }
  }

}
