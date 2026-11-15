# frozen_string_literal: true

describe Solargraph::CacheDir do
  it 'keeps pin caches in a directory named for the pin cache format' do
    expect(File.basename(described_class.work_dir))
      .to eq("solargraph-#{Solargraph::VERSION}-pins#{described_class::PIN_CACHE_FORMAT}")
  end
end
