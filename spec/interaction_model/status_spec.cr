require "../spec_helper"

module Matter::InteractionModel
  describe Status do
    describe "factories" do
      it "provides one factory per usable status code" do
        {
          Status.success                => StatusCode::Success,
          Status.failure                => StatusCode::Failure,
          Status.invalid_subscription   => StatusCode::InvalidSubscription,
          Status.unsupported_access     => StatusCode::UnsupportedAccess,
          Status.unsupported_endpoint   => StatusCode::UnsupportedEndpoint,
          Status.invalid_action         => StatusCode::InvalidAction,
          Status.unsupported_command    => StatusCode::UnsupportedCommand,
          Status.invalid_command        => StatusCode::InvalidCommand,
          Status.unsupported_attribute  => StatusCode::UnsupportedAttribute,
          Status.constraint_error       => StatusCode::ConstraintError,
          Status.unsupported_write      => StatusCode::UnsupportedWrite,
          Status.resource_exhausted     => StatusCode::ResourceExhausted,
          Status.not_found              => StatusCode::NotFound,
          Status.unreportable_attribute => StatusCode::UnreportableAttribute,
          Status.invalid_data_type      => StatusCode::InvalidDataType,
          Status.unsupported_read       => StatusCode::UnsupportedRead,
          Status.data_version_mismatch  => StatusCode::DataVersionMismatch,
          Status.timeout                => StatusCode::Timeout,
          Status.busy                   => StatusCode::Busy,
          Status.unsupported_cluster    => StatusCode::UnsupportedCluster,
        }.each do |status, code|
          status.status.should eq(code)
          status.cluster_status.should be_nil
        end
      end

      it "skips deprecated and reserved members" do
        Status.responds_to?(:deprecated82).should be_false
        Status.responds_to?(:reserved95).should be_false
      end

      it "reports success only for Success" do
        Status.success.success?.should be_true
        Status.failure.success?.should be_false
      end
    end

    describe ".cluster_failure" do
      it "is a Failure carrying the raw cluster status" do
        status = Status.cluster_failure(0x02_u8)
        status.status.should eq(StatusCode::Failure)
        status.cluster_status.should eq(0x02_u8)
      end

      it "accepts a cluster status enum" do
        status = Status.cluster_failure(Cluster::OperationalCredentials::NodeOperationalCertStatus::MissingCsr)
        status.status.should eq(StatusCode::Failure)
        status.cluster_status.should eq(Cluster::OperationalCredentials::NodeOperationalCertStatus::MissingCsr.value.to_u8)
      end
    end

    describe ".from_remote" do
      it "preserves recognized remote IM and cluster statuses" do
        Status.from_remote(StatusCode::ConstraintError.value).should eq(Status.constraint_error)
        Status.from_remote(StatusCode::Failure.value, 0x02_u8).should eq(Status.cluster_failure(0x02_u8))
      end

      it "maps an unknown remote code to Failure" do
        Status.from_remote(0xFE_u8).should eq(Status.failure)
      end
    end

    describe "#to_s" do
      it "interpolates the human readable label" do
        "#{Status.unsupported_attribute}".should eq("Unsupported Attribute")
        "#{StatusCode::InvalidDataType}".should eq("Invalid Data Type")
        Status.success.to_s.should eq("Success")
      end

      it "appends the cluster status when present" do
        "#{Status.cluster_failure(0x0A_u8)}".should eq("Failure (cluster: 0x0a)")
      end
    end
  end
end
