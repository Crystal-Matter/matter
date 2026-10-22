# Thread Network Directory

`Matter::Cluster::ThreadNetworkDirectory` implements the Matter 1.6 revision 1
server on an opt-in infrastructure endpoint. Add it to a Network Infrastructure
Manager endpoint when that device is intended to share Thread networks with
commissioners on its fabrics. The directory is common to all fabrics; Manage
ACL privilege protects writes and retrieval of full credentials. The
`GetOperationalDataset` handler additionally rejects sessions other than CASE.

The host supplies `table_size` and `supported_fabrics` when it constructs the
cluster. `table_size` must be at least twice the root Operational Credentials
`SupportedFabrics` value. Defaults are 32 and 16. If the device's configured
maximum differs, pass its actual value. `AddNetwork` and `RemoveNetwork` require
a timed interaction; the Interaction Model enforces that using command metadata.

Attach a persistent `Storage::Backend` to the device. It holds raw Thread
Operational Datasets, including the Network Key and PSKc. The host must protect
that storage and its backups. On factory reset the device erases cluster storage;
`factory_reset` also clears the in-memory directory. Obtain user consent before
changing an existing preferred network or contributing credentials to a new
directory. The cluster does not implement a consent UI or choose networks for
commissioners.

If this cluster is hosted by a Thread Border Router, the host must include and
keep up to date an entry for the router's own active Thread network. Crystal
Matter does not yet implement the Thread Border Router Management cluster or a
platform Thread stack adapter, so that synchronization remains a host duty.
The directory validates required Thread dataset TLVs and preserves unknown
TLVs. It does not assess Thread network reachability or the authenticity of
credentials supplied by another fabric.
