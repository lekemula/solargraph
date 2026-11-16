# frozen_string_literal: true

describe Solargraph::Environ do
  it 'merges gem names' do
    environ = described_class.new(gem_names: ['rspec-core'])
    environ.merge described_class.new(gem_names: ['rspec-mocks'])
    expect(environ.gem_names).to eq(%w[rspec-core rspec-mocks])
  end

  it 'clears gem names' do
    environ = described_class.new(gem_names: ['rspec-core'])
    expect(environ.clear.gem_names).to be_empty
  end
end
