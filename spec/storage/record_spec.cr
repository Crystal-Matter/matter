require "../spec_helper"

module RecordSpec
  include Matter::Storage

  enum Color
    Red
    Green
    Blue
  end

  @[Flags]
  enum Options : UInt8
    Alpha = 0x01
    Beta  = 0x02
  end

  struct Point
    include Matter::Storage::Record

    getter x : Int32
    getter y : Int32

    def initialize(@x : Int32, @y : Int32)
    end
  end

  class Everything
    include Matter::Storage::Record

    property? flag : Bool
    property name : String
    property i8 : Int8
    property i16 : Int16
    property i32 : Int32
    property i64 : Int64
    property u8 : UInt8
    property u16 : UInt16
    property u32 : UInt32
    property u64 : UInt64
    property f32 : Float32
    property f64 : Float64
    property bytes : Bytes
    property time : Time
    property color : Color
    property optional : String?
    property optional_point : Point?
    property point : Point
    property points : Array(Point)
    property numbers : Array(UInt16)
    property maybe_numbers : Array(Int32?)
    property by_id : Hash(UInt32, String)
    property by_name : Hash(String, Int64)
    property by_color : Hash(String, Color)

    @[Matter::Storage::Field(key: "renamed_key")]
    property renamed : String

    @[Matter::Storage::Field(ignore: true)]
    property cache : Int32 = 0

    @[Matter::Storage::Field(ignore: true)]
    property scratch : String?

    property with_default : String = "default"

    def initialize(
      @flag = true,
      @name = "thing",
      @i8 = Int8::MIN,
      @i16 = Int16::MAX,
      @i32 = -7,
      @i64 = Int64::MIN,
      @u8 = UInt8::MAX,
      @u16 = UInt16::MAX,
      @u32 = UInt32::MAX,
      @u64 = UInt64::MAX,
      @f32 = 1.5_f32,
      @f64 = 2.25,
      @bytes = Bytes[1, 2, 3],
      @time = Time.utc(2026, 9, 10, 1, 2, 3, nanosecond: 123_456_789),
      @color = Color::Green,
      @optional = nil,
      @optional_point = nil,
      @point = Point.new(1, 2),
      @points = [Point.new(3, 4), Point.new(5, 6)],
      @numbers = [1_u16, 65_535_u16],
      @maybe_numbers = [1, nil, 3] of Int32?,
      @by_id = {7_u32 => "seven", 8_u32 => "eight"},
      @by_name = {"a" => 1_i64},
      @by_color = {"primary" => Color::Red},
      @renamed = "renamed",
      @cache = 99,
      @scratch = "scratch",
    )
    end
  end

  class Base
    include Matter::Storage::Record

    getter id : Int32

    def initialize(@id : Int32)
    end
  end

  class Derived < Base
    getter label : String

    def initialize(@id : Int32, @label : String)
    end
  end

  def self.point_document(x : Type, y : Type) : Document
    Document{"x" => x, "y" => y}
  end
end

describe Matter::Storage::Record do
  describe "#to_document" do
    it "widens scalars to document types" do
      document = RecordSpec::Everything.new.to_document
      document["flag"].should be_true
      document["name"].should eq("thing")
      document["i8"].should eq(Int8::MIN.to_i64)
      document["i8"].should be_a(Int64)
      document["i16"].should be_a(Int64)
      document["i32"].should eq(-7_i64)
      document["i64"].should eq(Int64::MIN)
      document["u8"].should be_a(Int64)
      document["u16"].should eq(UInt16::MAX.to_i64)
      document["u32"].should eq(UInt32::MAX.to_i64)
      document["u64"].should eq(UInt64::MAX)
      document["u64"].should be_a(UInt64)
      document["f32"].should eq(1.5)
      document["f32"].should be_a(Float64)
      document["f64"].should eq(2.25)
      document["bytes"].should eq(Bytes[1, 2, 3])
      document["time"].should eq(Time.utc(2026, 9, 10, 1, 2, 3, nanosecond: 123_456_789))
      document["color"].should eq("Green")
    end

    it "omits nil fields" do
      document = RecordSpec::Everything.new.to_document
      document.has_key?("optional").should be_false
      document.has_key?("optional_point").should be_false

      document = RecordSpec::Everything.new(optional: "set", optional_point: RecordSpec::Point.new(0, 0)).to_document
      document["optional"].should eq("set")
      document["optional_point"].should eq(RecordSpec.point_document(0_i64, 0_i64))
    end

    it "nests records, arrays and hashes" do
      document = RecordSpec::Everything.new.to_document
      document["point"].should eq(RecordSpec.point_document(1_i64, 2_i64))
      document["points"].should eq([RecordSpec.point_document(3_i64, 4_i64), RecordSpec.point_document(5_i64, 6_i64)])
      document["numbers"].should eq([1_i64, 65_535_i64])
      document["maybe_numbers"].should eq([1_i64, nil, 3_i64])
      document["by_id"].should eq(Matter::Storage::Document{"7" => "seven", "8" => "eight"})
      document["by_name"].should eq(Matter::Storage::Document{"a" => 1_i64})
      document["by_color"].should eq(Matter::Storage::Document{"primary" => "Red"})
    end

    it "honours key renames and ignored fields" do
      document = RecordSpec::Everything.new.to_document
      document["renamed_key"].should eq("renamed")
      document.has_key?("renamed").should be_false
      document.has_key?("cache").should be_false
      document.has_key?("scratch").should be_false
    end
  end

  describe ".from_document" do
    it "round trips every field" do
      original = RecordSpec::Everything.new(optional: "set", optional_point: RecordSpec::Point.new(9, 9))
      restored = RecordSpec::Everything.from_document(original.to_document)

      restored.flag?.should eq(original.flag?)
      restored.name.should eq(original.name)
      restored.i8.should eq(original.i8)
      restored.i16.should eq(original.i16)
      restored.i32.should eq(original.i32)
      restored.i64.should eq(original.i64)
      restored.u8.should eq(original.u8)
      restored.u16.should eq(original.u16)
      restored.u32.should eq(original.u32)
      restored.u64.should eq(original.u64)
      restored.f32.should eq(original.f32)
      restored.f64.should eq(original.f64)
      restored.bytes.should eq(original.bytes)
      restored.time.should eq(original.time)
      restored.color.should eq(original.color)
      restored.optional.should eq("set")
      restored.optional_point.should eq(RecordSpec::Point.new(9, 9))
      restored.point.should eq(original.point)
      restored.points.should eq(original.points)
      restored.numbers.should eq(original.numbers)
      restored.maybe_numbers.should eq(original.maybe_numbers)
      restored.by_id.should eq(original.by_id)
      restored.by_name.should eq(original.by_name)
      restored.by_color.should eq(original.by_color)
      restored.renamed.should eq(original.renamed)
      restored.with_default.should eq(original.with_default)
    end

    it "round trips a false Bool" do
      restored = RecordSpec::Everything.from_document(RecordSpec::Everything.new(flag: false).to_document)
      restored.flag?.should be_false
    end

    it "round trips through a backend" do
      backend = Matter::Storage::Memory.new
      backend.write("records", "one", RecordSpec::Everything.new.to_document)
      restored = RecordSpec::Everything.from_document(backend.read("records", "one").as(Matter::Storage::Document))
      restored.u64.should eq(UInt64::MAX)
      restored.points.should eq([RecordSpec::Point.new(3, 4), RecordSpec::Point.new(5, 6)])
    end

    it "resets ignored fields to their defaults" do
      restored = RecordSpec::Everything.from_document(RecordSpec::Everything.new.to_document)
      restored.cache.should eq(0)
      restored.scratch.should be_nil
    end

    it "uses the default value for a missing field and nil for a missing nilable" do
      document = RecordSpec::Everything.new.to_document
      document.delete("with_default")
      document.delete("optional")
      restored = RecordSpec::Everything.from_document(document)
      restored.with_default.should eq("default")
      restored.optional.should be_nil
    end

    it "ignores extra keys" do
      document = RecordSpec.point_document(1_i64, 2_i64)
      document["z"] = 3_i64
      RecordSpec::Point.from_document(document).should eq(RecordSpec::Point.new(1, 2))
    end

    it "raises naming a missing required field" do
      expect_raises(Matter::StorageError, /Missing required field y for RecordSpec::Point/) do
        RecordSpec::Point.from_document(Matter::Storage::Document{"x" => 1_i64})
      end
    end

    it "raises naming an out of range integer" do
      expect_raises(Matter::StorageError, /Field x: 4294967296 is out of range for Int32/) do
        RecordSpec::Point.from_document(RecordSpec.point_document(Int64.new(UInt32::MAX) + 1, 0_i64))
      end

      document = RecordSpec::Everything.new.to_document
      document["u8"] = -1_i64
      expect_raises(Matter::StorageError, /Field u8: -1 is out of range for UInt8/) do
        RecordSpec::Everything.from_document(document)
      end

      document = RecordSpec::Everything.new.to_document
      document["i64"] = UInt64::MAX
      expect_raises(Matter::StorageError, /Field i64: .* out of range for Int64/) do
        RecordSpec::Everything.from_document(document)
      end
    end

    it "accepts integers stored as UInt64" do
      restored = RecordSpec::Point.from_document(RecordSpec.point_document(5_u64, 6_u64))
      restored.should eq(RecordSpec::Point.new(5, 6))
    end

    it "raises naming a field with the wrong type" do
      expect_raises(Matter::StorageError, /Field x: expected Int32, got String/) do
        RecordSpec::Point.from_document(RecordSpec.point_document("one", 0_i64))
      end

      document = RecordSpec::Everything.new.to_document
      document["points"] = "not a list"
      expect_raises(Matter::StorageError, /Field points: expected Array\(RecordSpec::Point\), got String/) do
        RecordSpec::Everything.from_document(document)
      end
    end

    it "raises on an unknown enum member" do
      document = RecordSpec::Everything.new.to_document
      document["color"] = "Purple"
      expect_raises(Matter::StorageError, /Field color: "Purple" is not a member of RecordSpec::Color/) do
        RecordSpec::Everything.from_document(document)
      end
    end

    it "reads an enum stored by value, as legacy imports are" do
      document = RecordSpec::Everything.new.to_document
      document["color"] = RecordSpec::Color::Blue.value.to_i64
      RecordSpec::Everything.from_document(document).color.should eq(RecordSpec::Color::Blue)

      document["color"] = RecordSpec::Color.values.size.to_i64
      expect_raises(Matter::StorageError, /Field color: #{RecordSpec::Color.values.size} is not a value of RecordSpec::Color/) do
        RecordSpec::Everything.from_document(document)
      end
    end

    it "restores combined flag names from persisted records" do
      decoded = Matter::Storage::Record.decode("Alpha | Beta", RecordSpec::Options, "options")
      decoded.should eq(RecordSpec::Options::Alpha | RecordSpec::Options::Beta)
      expect_raises(Matter::StorageError, /Field options/) do
        Matter::Storage::Record.decode("Alpha | Unknown", RecordSpec::Options, "options")
      end
    end

    it "raises on a hash key that is not an integer" do
      document = RecordSpec::Everything.new.to_document
      document["by_id"] = Matter::Storage::Document{"seven" => "7"}
      expect_raises(Matter::StorageError, /Field by_id: key "seven" is not an integer/) do
        RecordSpec::Everything.from_document(document)
      end

      document["by_id"] = Matter::Storage::Document{"-1" => "minus one"}
      expect_raises(Matter::StorageError, /Field by_id: key -1 is out of range for UInt32/) do
        RecordSpec::Everything.from_document(document)
      end
    end

    it "reports errors inside nested records with the nested field name" do
      document = RecordSpec::Everything.new.to_document
      document["point"] = Matter::Storage::Document{"x" => 1_i64}
      expect_raises(Matter::StorageError, /Missing required field y for RecordSpec::Point/) do
        RecordSpec::Everything.from_document(document)
      end
    end

    it "supports subclasses" do
      derived = RecordSpec::Derived.new(4, "four")
      document = derived.to_document
      document.should eq(Matter::Storage::Document{"id" => 4_i64, "label" => "four"})
      restored = RecordSpec::Derived.from_document(document)
      restored.id.should eq(4)
      restored.label.should eq("four")
    end
  end
end
