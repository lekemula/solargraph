# frozen_string_literal: true

describe Solargraph::Diagnostics::YardLint do
  let(:fixture_path) do
    File.absolute_path('spec/fixtures/yard-lint-offense').gsub('\\', '/')
  end

  it 'returns [] for sources without an on-disk filename' do
    source = Solargraph::Source.new("# @return [void]\ndef foo; end\n", '')
    yard_lint = described_class.new
    expect(yard_lint.diagnose(source, nil)).to eq([])
  end

  it 'returns [] when buffer contents differ from disk' do
    file = File.realpath(File.join(fixture_path, 'app.rb'))
    source = Solargraph::Source.new("# different\n", file)
    yard_lint = described_class.new
    expect(yard_lint.diagnose(source, nil)).to eq([])
  end

  context 'with a local yard-lint config' do
    around do |example|
      Dir.chdir(fixture_path) { example.run }
    end

    it 'diagnoses input' do
      file = File.realpath(File.join(fixture_path, 'app.rb'))
      source = Solargraph::Source.load(file)
      yard_lint = described_class.new
      result = yard_lint.diagnose(source, nil)
      expect(result).to be_a(Array)
    end

    it 'calculates ranges' do
      file = File.realpath(File.join(fixture_path, 'app.rb'))
      source = Solargraph::Source.load(file)
      yard_lint = described_class.new
      results = yard_lint.diagnose(source, nil)

      expect(results).not_to be_empty
      offense = results.first
      expect(offense[:source]).to eq('yard-lint')
      expect(offense[:severity]).to eq(Solargraph::Diagnostics::Severities::ERROR)
      expect(offense[:code]).to eq('UnknownParameterName')
      expect(offense[:range][:start][:line]).to eq(5)
      expect(offense[:range][:start][:character]).to eq(0)
      expect(offense[:range][:end][:line]).to eq(5)
      expect(offense[:range][:end][:character]).to eq('def my_method(foo)'.length)
    end
  end
end
