# Descriptor endpoint composition

Device endpoint declarations can name a parent with `parent_endpoint:`. The
default is endpoint 0, preserving existing flat devices. `tag_list:` accepts
one to six `Matter::Cluster::Descriptor::SemanticTag` entries and enables the
Descriptor `TAGLIST` feature and read-only attribute `0x0004` on that endpoint.

```crystal
alias Descriptor = Matter::Cluster::Descriptor

endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
end

endpoint 2, device_type: Matter::DeviceType::ON_OFF_LIGHT,
  parent_endpoint: 1_u16,
  tag_list: [Descriptor::SemanticTag.new(nil, 1_u8, 1_u8)] do
  # Required device-type clusters go here.
end
```

The root Descriptor lists every other endpoint. A nonroot Aggregator also
lists all descendants; other composed endpoints list direct children. Static
composition rejects a missing parent or a cycle. A dynamic endpoint must name
an existing parent, and a parent cannot be removed while it still has children.
Dynamic endpoints built from a template persist their parent link. A template
may declare a fixed `tag_list:`; low-level `add_endpoint` also accepts
`parent_endpoint:` and `tag_list:`. Existing low-level dynamic endpoints remain
the application's responsibility to recreate after restart.

Core Matter 1.6 limits Descriptor TagList to six entries. A manufacturer tag
must appear alongside a standard tag, and labels are allowed only on
manufacturer tags with at most 64 UTF-8 bytes. Device-specific requirements
for which sibling endpoints need distinct tags still belong to the device
composition and certification review.
