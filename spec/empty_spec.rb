# frozen_string_literal: true

describe Solargraph::Empty do
  it 'shares one frozen empty array and hash' do
    expect(described_class::ARRAY).to eq([])
    expect(described_class::ARRAY).to be_frozen
    expect(described_class::HASH).to eq({})
    expect(described_class::HASH).to be_frozen
  end

  it 'keeps the shared instances across a Marshal round-trip' do
    loaded = Marshal.load(Marshal.dump([described_class::ARRAY, described_class::HASH]))

    expect(loaded[0]).to be(described_class::ARRAY)
    expect(loaded[1]).to be(described_class::HASH)
  end

  it 'swaps empty collections for the shared ones' do
    expect(described_class.share_array([])).to be(described_class::ARRAY)
    expect(described_class.share_hash({})).to be(described_class::HASH)
    expect(described_class.share_array([1])).to eq([1])
  end

  it 'gives plain mutable collections from dup' do
    array = described_class::ARRAY.dup << 1
    hash = described_class::HASH.dup.merge!('a' => 1)

    expect(array).to be_instance_of(Array)
    expect(hash).to be_instance_of(Hash)
  end

  it 'keeps the content of derived non-empty collections across a Marshal round-trip' do
    hash = described_class::HASH.merge('a' => 1)

    expect(Marshal.load(Marshal.dump(hash))).to eq('a' => 1)
  end
end
