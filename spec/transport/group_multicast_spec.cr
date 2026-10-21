require "../spec_helper"

describe Matter::Transport::GroupMulticast do
  it "builds the PerGroupId address from fabric and group IDs" do
    address = Matter::Transport::GroupMulticast.address(0x1234_5678_9abc_def0_u64, 0x0102_u16)
    address.address.should eq("ff35:40:fd12:3456:789a:bcde:f000:102")
    address.port.should eq(5540)
    expect_raises(ArgumentError) { Matter::Transport::GroupMulticast.address(1_u64, 0_u16) }
  end
end
