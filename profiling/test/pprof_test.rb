# frozen_string_literal: true

# rubocop:disable Minitest/MultipleAssertions

require_relative 'test_helper'

class PprofTest < Minitest::Test
  include ProfileWire

  def test_leaf_order_depth_weight_units_and_labels
    data = { mode: :object, interval: 10, samples: 2,
             frames: { 100 => { name: 'root' }, 200 => { name: 'leaf' } },
             raw: [2, 100, 200, 2], labels: { 0 => { 'thread id' => '42' } } }
    profile = decode(Zlib.gunzip(Beacon::Profiling::Pprof.encode(data, 123, 456, max_frames: 1)))
    strings = profile[6]
    types = profile[1].map do |value|
      type = decode(value)
      [strings[type[1].first], strings[type[2].first]]
    end
    assert_equal [%w[samples count], %w[alloc-samples count]], types
    sample = decode(profile[2].first)
    assert_equal [2], sample[1]
    assert_equal [2, 20], sample[2]
    label = decode(sample[3].first)
    assert_equal 'thread id', strings[label[1].first]
    assert_equal '42', strings[label[2].first]
    assert_equal [123], profile[9]
    assert_equal [456], profile[10]
    assert_equal [10], profile[12]
  end

  def test_profiler_samples_are_filtered_before_depth_truncation
    data = { mode: :cpu, interval: 10_000, samples: 1,
             frames: { 1 => { name: 'export', file: File.expand_path('../lib/beacon/profiling/session.rb', __dir__) },
                       2 => { name: 'allocate', file: 'application.rb' } }, raw: [2, 1, 2, 1] }
    assert_nil Beacon::Profiling::Pprof.encode(data, 1, 2, max_frames: 1)
    refute_nil Beacon::Profiling::Pprof.encode(data, 1, 2, max_frames: 1, ignore_profiler: false)
  end

  def test_one_profile_contains_all_four_types_with_aligned_values_and_unique_locations
    profiles = %i[cpu wall object exceptions].map do |mode|
      { mode: mode, interval: 10, samples: 2, frames: { 1 => { name: mode.to_s } }, raw: [1, 1, 2] }
    end
    profile = decode(Zlib.gunzip(Beacon::Profiling::Pprof.encode(profiles, 1, 60_000_000_000)))
    strings = profile[6]
    names = profile[1].map { |type| strings[decode(type)[1].first] }
    assert_equal %w[samples cpu-time wall-time alloc-samples exception-samples], names
    samples = profile[2].map { |sample| decode(sample) }
    assert_equal([[2, 20_000, 0, 0, 0], [2, 0, 20_000, 0, 0], [2, 0, 0, 20, 0], [2, 0, 0, 0, 20]], samples.map { |sample| sample[2] })
    assert_equal 4, samples.flat_map { |sample| sample[1] }.uniq.length
    assert_empty profile[11]
  end

  def test_heap_gauges_use_last_snapshot_while_cpu_samples_accumulate
    first_heap = { mode: :heap_size, interval: 1, frames: { 1 => { name: 'allocate' } }, raw: [1, 1, 100] }
    last_heap = first_heap.merge(raw: [1, 1, 200])
    cpu = { mode: :cpu, interval: 1000, frames: { 1 => { name: 'compute' } }, raw: [1, 1, 3] }
    profile = decode(Zlib.gunzip(Beacon::Profiling::Pprof.encode([first_heap, cpu, last_heap, cpu], 1, 2)))
    strings = profile[6]
    types = profile[1].map { |value| strings[decode(value)[1].first] }
    values = profile[2].map { |sample| decode(sample)[2] }
    assert_equal(200, values.sum { |row| row[types.index('heap-live-size')] })
    assert_equal(6_000_000, values.sum { |row| row[types.index('cpu-time')] })
    heap_type = decode(profile[1][types.index('heap-live-size')])
    assert_equal 'bytes', strings[heap_type[2].first]
  end

  def test_final_empty_heap_slice_clears_previous_gauges_without_losing_cpu
    heap = { interval: 1, samples: 1, frames: { 1 => { name: 'allocate' } }, raw: [1, 1, 200] }
    first = %i[heap_objects heap_size].map { |mode| heap.merge(mode: mode) }
    empty = first.map { |entry| entry.merge(samples: 0, frames: {}, raw: []) }
    collector = Struct.new(:snapshots) do
      def snapshot
        snapshots.shift
      end
    end.new([first, empty])
    config = Beacon::Profiling::Config.new('OTEL_PROFILING_TYPES' => 'cpu', 'OTEL_PROFILING_EXPORTER' => 'pprof')
    session = Beacon::Profiling::Session.new(config)
    session.instance_variable_set(:@native, collector)
    session.instance_variable_set(:@monotonic, Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond))
    entries = session.send(:snapshot).first + session.send(:snapshot).first
    cpu = { mode: :cpu, interval: 1000, samples: 3, frames: { 1 => { name: 'compute' } }, raw: [1, 1, 3] }
    encoded = Beacon::Profiling::Pprof.encode([cpu, *entries], 1, 2)
    profile = decode(Zlib.gunzip(encoded))
    strings = profile[6]
    types = profile[1].map { |value| strings[decode(value)[1].first] }
    assert_equal %w[samples cpu-time], types
    assert_equal [3, 3_000_000], decode(profile[2].first)[2]
    assert_nil Beacon::Profiling::Pprof.encode(entries, 1, 2)
  end

  def test_file_exports_keep_each_native_slices_start_and_duration
    Dir.mktmpdir do |dir|
      config = Beacon::Profiling::Config.new('OTEL_PROFILING_PPROF_PATH' => dir)
      session = Beacon::Profiling::Session.new(config)
      slice = 30_000_000_000
      started = 1_700_000_000_000_000_000
      clock = [slice, slice * 2]
      session.define_singleton_method(:monotonic) { clock.shift }
      entries = %i[cpu object].each_with_index.flat_map do |mode, index|
        profile = { mode: mode, interval: 1000, samples: 1, frames: { 1 => { name: 'work' } }, raw: [1, 1, 1] }
        collector = Struct.new(:profile) do
          def snapshot
            [profile]
          end
        end.new(profile)
        session.instance_variable_set(:@native, collector)
        session.instance_variable_set(:@started, started + (index * slice))
        session.instance_variable_set(:@monotonic, index * slice)
        session.send(:snapshot).first
      end
      session.send(:export_batch, entries, started, slice * 2)
      %w[cpu object].each_with_index do |mode, index|
        file = Dir[File.join(dir, "ruby-#{mode}-*.pprof")].fetch(0)
        profile = decode(Zlib::GzipReader.open(file, &:read))
        assert_equal [started + (index * slice)], profile[9]
        assert_equal [slice], profile[10]
      end
    end
  end
end

# rubocop:enable Minitest/MultipleAssertions
