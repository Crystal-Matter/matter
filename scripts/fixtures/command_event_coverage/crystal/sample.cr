class Sample
  cluster 0x1234, revision: 3
  command 0x00, :present
  command 0x02, :feature_command, requires: :test
  event 0x02, :feature_event, priority: :info
end
