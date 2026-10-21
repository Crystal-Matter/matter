require "../support/group_key_management_helpers"

module Matter::Cluster
  describe GroupKeyManagement do
    describe "group key map operations" do
      it "adds group key map entry" do
        cluster = build(GroupKeyManagement, 0)
        fabric_index = 1_u8

        # Create key set
        cluster.handle_key_set_write(
          GroupKeyManagement::KeySetWriteRequest.new(Cluster.create_key_set(id: 1_u16)),
          fabric_index
        )

        # Add mapping
        cluster.add_group_key_map(group_id: 100_u16, group_key_set_id: 1_u16, fabric_index: fabric_index)

        entries = cluster.group_key_map(fabric_index)
        entries.size.should eq(1)
        entries[0].group_id.should eq(100_u16)
        entries[0].group_key_set_id.should eq(1_u16)
      end

      it "updates existing group key map entry" do
        cluster = build(GroupKeyManagement, 0)
        fabric_index = 1_u8

        # Create two key sets
        cluster.handle_key_set_write(
          GroupKeyManagement::KeySetWriteRequest.new(Cluster.create_key_set(id: 1_u16)),
          fabric_index
        )
        cluster.handle_key_set_write(
          GroupKeyManagement::KeySetWriteRequest.new(Cluster.create_key_set(id: 2_u16)),
          fabric_index
        )

        # Add mapping
        cluster.add_group_key_map(100_u16, 1_u16, fabric_index)

        # Update mapping to different key set
        cluster.add_group_key_map(100_u16, 2_u16, fabric_index)

        entries = cluster.group_key_map(fabric_index)
        entries.size.should eq(1)                    # Still only one entry
        entries[0].group_key_set_id.should eq(2_u16) # Updated
      end

      it "rejects group ID 0" do
        cluster = build(GroupKeyManagement, 0)
        fabric_index = 1_u8

        cluster.handle_key_set_write(
          GroupKeyManagement::KeySetWriteRequest.new(Cluster.create_key_set(id: 1_u16)),
          fabric_index
        )

        error = expect_raises(Matter::ClusterError, /Group ID 0 is invalid/) do
          cluster.add_group_key_map(0_u16, 1_u16, fabric_index)
        end
        error.status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
      end

      it "rejects non-existent key set" do
        cluster = build(GroupKeyManagement, 0)

        error = expect_raises(Matter::ClusterError, /Key set 99 does not exist/) do
          cluster.add_group_key_map(100_u16, 99_u16, fabric_index: 1)
        end
        error.status.should eq(Matter::InteractionModel::StatusCode::NotFound)
      end

      it "enforces max_groups_per_fabric limit" do
        cluster = build(GroupKeyManagement, 0, max_groups_per_fabric: 2_u16)
        fabric_index = 1_u8

        # Create key set
        cluster.handle_key_set_write(
          GroupKeyManagement::KeySetWriteRequest.new(Cluster.create_key_set(id: 1_u16)),
          fabric_index
        )

        # Add two groups (should succeed)
        cluster.add_group_key_map(100_u16, 1_u16, fabric_index)
        cluster.add_group_key_map(200_u16, 1_u16, fabric_index)

        # Third group should fail
        error = expect_raises(Matter::ClusterError, /Cannot exceed max_groups_per_fabric/) do
          cluster.add_group_key_map(300_u16, 1_u16, fabric_index)
        end
        error.status.should eq(Matter::InteractionModel::StatusCode::ResourceExhausted)
      end

      it "removes group key map entry" do
        cluster = build(GroupKeyManagement, 0)
        fabric_index = 1_u8

        cluster.handle_key_set_write(
          GroupKeyManagement::KeySetWriteRequest.new(Cluster.create_key_set(id: 1_u16)),
          fabric_index
        )
        cluster.add_group_key_map(100_u16, 1_u16, fabric_index)

        cluster.remove_group_key_map(100_u16, fabric_index)

        cluster.group_key_map(fabric_index).should be_empty
      end

      it "isolates fabrics" do
        cluster = build(GroupKeyManagement, 0)

        # Create key sets in different fabrics
        cluster.handle_key_set_write(
          GroupKeyManagement::KeySetWriteRequest.new(Cluster.create_key_set(id: 1_u16)),
          fabric_index: 1
        )
        cluster.handle_key_set_write(
          GroupKeyManagement::KeySetWriteRequest.new(Cluster.create_key_set(id: 1_u16)),
          fabric_index: 2
        )

        # Add mappings in both fabrics with same group ID
        cluster.add_group_key_map(100_u16, 1_u16, fabric_index: 1)
        cluster.add_group_key_map(100_u16, 1_u16, fabric_index: 2)

        # Each fabric should only see its own mapping
        cluster.group_key_map(fabric_index: 1).size.should eq(1)
        cluster.group_key_map(fabric_index: 2).size.should eq(1)
      end
    end

    describe "group table operations" do
      it "adds group to table" do
        cluster = build(GroupKeyManagement, 0)
        fabric_index = 1_u8

        # Setup: key set + mapping
        cluster.handle_key_set_write(
          GroupKeyManagement::KeySetWriteRequest.new(Cluster.create_key_set(id: 1_u16)),
          fabric_index
        )
        cluster.add_group_key_map(100_u16, 1_u16, fabric_index)

        # Add group
        cluster.add_group(100_u16, endpoint_id: 1_u16, group_name: "Test Group", fabric_index: fabric_index)

        groups = cluster.group_table(fabric_index)
        groups.size.should eq(1)
        groups[0].group_id.should eq(100_u16)
        groups[0].endpoints.should eq([1_u16])
        groups[0].group_name.should eq("Test Group")
      end

      it "adds endpoint to existing group" do
        cluster = build(GroupKeyManagement, 0)
        fabric_index = 1_u8

        # Setup
        cluster.handle_key_set_write(
          GroupKeyManagement::KeySetWriteRequest.new(Cluster.create_key_set(id: 1_u16)),
          fabric_index
        )
        cluster.add_group_key_map(100_u16, 1_u16, fabric_index)

        # Add group with first endpoint
        cluster.add_group(100_u16, endpoint_id: 1_u16, group_name: "Test", fabric_index: fabric_index)

        # Add second endpoint
        cluster.add_group(100_u16, endpoint_id: 2_u16, group_name: nil, fabric_index: fabric_index)

        groups = cluster.group_table(fabric_index)
        groups.size.should eq(1)
        groups[0].endpoints.should eq([1_u16, 2_u16])
      end

      it "allows group membership before key map provisioning" do
        cluster = build(GroupKeyManagement, 0)
        fabric_index = 1_u8

        cluster.add_group(100_u16, endpoint_id: 1_u16, group_name: nil, fabric_index: fabric_index)
        cluster.group_table(fabric_index).first.endpoints.should eq([1_u16])
        cluster.group_key_map(fabric_index).should be_empty
      end

      it "enforces max_groups_per_fabric limit" do
        cluster = build(GroupKeyManagement, 0, max_groups_per_fabric: 2_u16)
        fabric_index = 1_u8

        # Setup key set
        cluster.handle_key_set_write(
          GroupKeyManagement::KeySetWriteRequest.new(Cluster.create_key_set(id: 1_u16)),
          fabric_index
        )

        # Add two groups (should succeed)
        [100_u16, 200_u16].each do |group_id|
          cluster.add_group_key_map(group_id, 1_u16, fabric_index)
          cluster.add_group(group_id, endpoint_id: 1_u16, group_name: nil, fabric_index: fabric_index)
        end

        # Third group should fail when adding key map
        error = expect_raises(Matter::ClusterError, /Cannot exceed max_groups_per_fabric/) do
          cluster.add_group_key_map(300_u16, 1_u16, fabric_index)
        end
        error.status.should eq(Matter::InteractionModel::StatusCode::ResourceExhausted)
      end

      it "removes endpoint from group" do
        cluster = build(GroupKeyManagement, 0)
        fabric_index = 1_u8

        # Setup
        cluster.handle_key_set_write(
          GroupKeyManagement::KeySetWriteRequest.new(Cluster.create_key_set(id: 1_u16)),
          fabric_index
        )
        cluster.add_group_key_map(100_u16, 1_u16, fabric_index)
        cluster.add_group(100_u16, endpoint_id: 1_u16, group_name: nil, fabric_index: fabric_index)
        cluster.add_group(100_u16, endpoint_id: 2_u16, group_name: nil, fabric_index: fabric_index)

        # Remove one endpoint
        cluster.remove_group(100_u16, endpoint_id: 1_u16, fabric_index: fabric_index)

        groups = cluster.group_table(fabric_index)
        groups.size.should eq(1)
        groups[0].endpoints.should eq([2_u16])
      end

      it "removes group when last endpoint removed" do
        cluster = build(GroupKeyManagement, 0)
        fabric_index = 1_u8

        # Setup
        cluster.handle_key_set_write(
          GroupKeyManagement::KeySetWriteRequest.new(Cluster.create_key_set(id: 1_u16)),
          fabric_index
        )
        cluster.add_group_key_map(100_u16, 1_u16, fabric_index)
        cluster.add_group(100_u16, endpoint_id: 1_u16, group_name: nil, fabric_index: fabric_index)

        # Remove last endpoint
        cluster.remove_group(100_u16, endpoint_id: 1_u16, fabric_index: fabric_index)

        cluster.group_table(fabric_index).should be_empty
      end

      it "isolates fabrics" do
        cluster = build(GroupKeyManagement, 0)

        # Setup two fabrics
        [1_u8, 2_u8].each do |fabric_index|
          cluster.handle_key_set_write(
            GroupKeyManagement::KeySetWriteRequest.new(Cluster.create_key_set(id: 1_u16)),
            fabric_index
          )
          cluster.add_group_key_map(100_u16, 1_u16, fabric_index)
          cluster.add_group(100_u16, endpoint_id: 1_u16, group_name: "Fabric #{fabric_index}", fabric_index: fabric_index)
        end

        # Each fabric should only see its own group
        groups1 = cluster.group_table(fabric_index: 1)
        groups1.size.should eq(1)
        groups1[0].group_name.should eq("Fabric 1")

        groups2 = cluster.group_table(fabric_index: 2)
        groups2.size.should eq(1)
        groups2[0].group_name.should eq("Fabric 2")
      end
    end

    describe "fabric management" do
      it "removes all data for fabric" do
        cluster = build(GroupKeyManagement, 0)
        fabric_index = 1_u8

        # Create comprehensive data
        cluster.handle_key_set_write(
          GroupKeyManagement::KeySetWriteRequest.new(Cluster.create_key_set(id: 1_u16)),
          fabric_index
        )
        cluster.add_group_key_map(100_u16, 1_u16, fabric_index)
        cluster.add_group(100_u16, endpoint_id: 1_u16, group_name: nil, fabric_index: fabric_index)

        # Remove fabric
        cluster.remove_fabric(fabric_index)

        # All data should be gone
        cluster.handle_key_set_read_all_indices(fabric_index).group_key_set_i_ds.should be_empty
        cluster.group_key_map(fabric_index).should be_empty
        cluster.group_table(fabric_index).should be_empty
      end

      it "only removes data for specified fabric" do
        cluster = build(GroupKeyManagement, 0)

        # Create data in two fabrics
        [1_u8, 2_u8].each do |fabric_index|
          cluster.handle_key_set_write(
            GroupKeyManagement::KeySetWriteRequest.new(Cluster.create_key_set(id: 1_u16)),
            fabric_index
          )
          cluster.add_group_key_map(100_u16, 1_u16, fabric_index)
          cluster.add_group(100_u16, endpoint_id: 1_u16, group_name: nil, fabric_index: fabric_index)
        end

        # Remove fabric 1
        cluster.remove_fabric(fabric_index: 1)

        # Fabric 1 should be empty
        cluster.handle_key_set_read_all_indices(fabric_index: 1).group_key_set_i_ds.should be_empty

        # Fabric 2 should still have data
        cluster.handle_key_set_read_all_indices(fabric_index: 2).group_key_set_i_ds.should eq([1_u16])
        cluster.group_key_map(fabric_index: 2).size.should eq(1)
        cluster.group_table(fabric_index: 2).size.should eq(1)
      end
    end

    describe "helper methods" do
      it "checks group existence" do
        cluster = build(GroupKeyManagement, 0)
        fabric_index = 1_u8

        # Setup
        cluster.handle_key_set_write(
          GroupKeyManagement::KeySetWriteRequest.new(Cluster.create_key_set(id: 1_u16)),
          fabric_index
        )
        cluster.add_group_key_map(100_u16, 1_u16, fabric_index)
        cluster.add_group(100_u16, endpoint_id: 1_u16, group_name: nil, fabric_index: fabric_index)

        cluster.group_exists?(100_u16, fabric_index).should be_true
        cluster.group_exists?(999_u16, fabric_index).should be_false
      end

      it "retrieves key set with actual key material" do
        cluster = build(GroupKeyManagement, 0)
        fabric_index = 1_u8
        key_bytes = Cluster.test_key(0xAA)
        key_set = Cluster.create_key_set(id: 1_u16, key0: key_bytes, time0: 1000_u64)

        cluster.handle_key_set_write(
          GroupKeyManagement::KeySetWriteRequest.new(key_set),
          fabric_index
        )

        # get_key_set should return actual keys (for crypto operations)
        retrieved = cluster.get_key_set(1_u16, fabric_index)
        retrieved.should_not be_nil
        retrieved.as(GroupKeyManagement::GroupKeySetStruct).epoch_key0.should eq(key_bytes)
      end

      it "returns nil for non-existent key set" do
        cluster = build(GroupKeyManagement, 0)
        retrieved = cluster.get_key_set(99_u16, fabric_index: 1)
        retrieved.should be_nil
      end
    end
  end
end
