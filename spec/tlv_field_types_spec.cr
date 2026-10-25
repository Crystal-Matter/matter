require "./spec_helper"

# A structural guard over every `TLV::Serializable` field in the library.
#
# The door-lock bug was a payload declaring a field with a datatype wrapper the
# TLV shard cannot put on the wire, which turned every lock command into a
# `Failure` against a real controller. Nothing caught it, because a field type
# the shard does not know about is only a problem at the moment a message is
# actually encoded or decoded - and an event that no spec exercises end to end
# never reaches that moment.
#
# So walk the declarations instead of the traffic: every includer of
# `TLV::Serializable`, every instance variable carrying a `TLV::Field`
# annotation, flattened through nilable unions, `TLV::FieldState(...)`,
# `Array(...)` and tuples, and
# assert that nothing is left over.
#
# Both directions are checked, because they are answered by different overload
# sets: `serialize_value` for the encoder, `deserialize_value` for the decoder.
# Each set is read out of the shard at macro time rather than hand-maintained,
# so a type this library registers through `define_id`
# (`src/matter/datatype/id.cr`) counts as supported without being listed here.
#
# Until tlv 1.1.0 the two were not symmetric: the decoder's union branch matched
# a closed list of members with no fallback, so a registered type encoded as a
# field and then raised on `from_slice` the moment the field became nilable.
# That is fixed upstream; this spec now holds both sides to the same rule.
module TLVFieldTypes
  # Fields whose type the encoder cannot serialize.
  #
  # The supported set is read out of the shard at macro time rather than
  # hand-maintained: every `TLV::Serializable.serialize_value` overload, which
  # includes the ones `define_id` registers from this library.
  def self.encode_violations : Array(String)
    violations = [] of String

    # One `{% begin %}` for the whole walk: macro variables do not survive
    # across sibling `{% %}` blocks in a method body.
    {% begin %}
      {%
        encodable = ::TLV::Serializable.class.methods
          .select { |method| method.name.stringify == "serialize_value" }
          .map(&.args.[0].restriction.resolve?)
          .reject(&.==(nil))
      %}
      {% for struct_type in ::TLV::Serializable.includers %}
        {% for ivar in struct_type.instance_vars %}
          {% if ivar.annotation(::TLV::Field) %}
            # Flatten the declaration to the scalar types actually handed to the
            # encoder: union members, then one level of Array/Tuple element type,
            # then that element type's own union members or element types.
            {% leaves = [] of Nil %}
            {% members = ivar.type.union? ? ivar.type.union_types : [ivar.type] %}
            {% for member in members %}
              # FieldState is serialized by the shard's field macro; its
              # payload still needs an ordinary typed value codec.
              {% field_type = member.name.starts_with?("TLV::FieldState(") || member.name.starts_with?("::TLV::FieldState(") ? member.type_vars.first : member %}
              {% if field_type.name.starts_with?("Array(") || field_type.name.starts_with?("Tuple(") %}
                {% for element in field_type.type_vars %}
                  {% if element.union? %}
                    {% for inner in element.union_types %}{% leaves << inner %}{% end %}
                  {% elsif element.name.starts_with?("Array(") || element.name.starts_with?("Tuple(") %}
                    {% for inner in element.type_vars %}{% leaves << inner %}{% end %}
                  {% else %}
                    {% leaves << element %}
                  {% end %}
                {% end %}
              {% else %}
                {% leaves << field_type %}
              {% end %}
            {% end %}

            {% for leaf in leaves %}
              {% unless encodable.includes?(leaf) || leaf < Enum || leaf < ::TLV::Serializable %}
                violations << {{ "#{struct_type.name}##{ivar.name} : #{ivar.type} - no TLV::Serializable.serialize_value overload for #{leaf.name}" }}
              {% end %}
            {% end %}
          {% end %}
        {% end %}
      {% end %}
    {% end %}

    violations
  end

  # Union-typed fields the decoder cannot reconstruct. A union member has to be
  # a type the shard's union branch recognises, or one with a registered
  # `deserialize_value` overload that the branch now falls back to. A
  # `@[TLV::ListFormat]` struct is excluded: that branch matches a member struct
  # on a structure element, and a list-format struct is not one.
  def self.decode_violations : Array(String)
    violations = [] of String

    {% begin %}
      {%
        decodable = ::TLV::Serializable.class.methods
          .select { |method| method.name.stringify == "deserialize_value" }
          .map(&.args.[1].restriction.resolve?)
          .reject(&.==(nil))
          .map(&.instance)
      %}
      {% for struct_type in ::TLV::Serializable.includers %}
        {% for ivar in struct_type.instance_vars %}
          {% if ivar.annotation(::TLV::Field) && ivar.type.union? %}
            {% for member in ivar.type.union_types %}
              {% unless decodable.includes?(member) ||
                          member < Enum ||
                          member.name.starts_with?("Array(") ||
                          (member < ::TLV::Serializable && !member.annotation(::TLV::ListFormat)) %}
                violations << {{ "#{struct_type.name}##{ivar.name} : #{ivar.type} - union member #{member.name} is not decodable inside a union" }}
              {% end %}
            {% end %}
          {% end %}
        {% end %}
      {% end %}
    {% end %}

    violations
  end
end

describe "TLV::Serializable field types" do
  it "declares no field the encoder cannot serialize" do
    TLVFieldTypes.encode_violations.should be_empty
  end

  it "declares no union member the decoder cannot deserialize" do
    TLVFieldTypes.decode_violations.should be_empty
  end
end
