module Matter
  class Device
    # Declarative device definitions for `Matter::Device` subclasses.
    #
    # ```
    # class Switch < Matter::Device
    #   identity vendor: "Spider-Gazelle", product: "Crystal Switch",
    #     vendor_id: Matter::SetupPayload.test_vendor_id, product_id: 0x8001_u16,
    #     discriminator: 3840_u16, pin: 20202021_u32,
    #     device_type: Matter::DeviceType::ON_OFF_LIGHT, appearance: :satin
    #   storage yaml: "matter_switch_storage.yml"
    #   network :ethernet
    #
    #   endpoint 1, device_type: Matter::DeviceType::ON_OFF_LIGHT do
    #     cluster Matter::Cluster::OnOff, feature_map: :lighting, as: :switch
    #     cluster Matter::Cluster::Identify, identify_type: :visible_light
    #     cluster Matter::Cluster::Groups
    #   end
    #
    #   on(:switch, :state_changed) { |state| puts "switch #{state}" }
    # end
    # ```
    #
    # Declarations:
    #
    # * `identity vendor:, product:, vendor_id:, product_id:, discriminator:,
    #   pin:, device_type:` and the optional `appearance:`,
    #   `hardware_version:`, `hardware_version_string:`, `software_version:`,
    #   `software_version_string:`, `serial_number:`, `unique_id:` — the
    #   identity methods `Device` otherwise leaves to the subclass. Each value
    #   is evaluated once, into a constant, so a randomised id stays stable for
    #   the life of the process.
    # * `storage yaml: "path"` / `storage json: "path"` / `storage :memory` —
    #   the `initialize` that opens the backend. Every `Device#initialize`
    #   argument stays available, so a spec can pass its own backend.
    # * `network :ethernet | :wifi | :thread` — the Network Commissioning
    #   cluster's network type and feature map.
    # * `managed_restrictions requested: :method, updated: :method` — opt in
    #   to the Access Control ManagedDevice feature. Both instance methods
    #   handle durable, token-correlated host consent callbacks.
    # * `endpoint number, device_type: do ... end` — an endpoint and its
    #   clusters. The block holds `cluster` declarations; the endpoint's device
    #   type goes into `endpoint_device_types`, and `Endpoint#validate` holds
    #   the endpoint to it.
    # * `cluster Klass, *args, **options, as: :name` — one cluster of the
    #   enclosing endpoint, built as `Klass.new(endpoint_number, *args,
    #   **options)`. `as:` adds a typed accessor for it (`switch : OnOff`),
    #   which is what `on` and the application read.
    # * `client_cluster id` — an outbound cluster ID in Descriptor.ClientList;
    #   it does not build or advertise a local server.
    # * `endpoint_template :name, device_type:, parameters: {key: Type} do ... end` —
    #   the shape of an endpoint added at runtime with
    #   `add_endpoint(:name, key: value)`. The parameters are named locals in
    #   the block and are persisted with the endpoint, so it comes back after a
    #   restart. `device_type:` takes one id or an array of them.
    # * `on(:accessor, :event) { |...| }` — installs the block as
    #   `accessor.on_event`. Every callback is wired once every endpoint is
    #   built, so a callback may reference an accessor from another endpoint.
    #
    # Generated into the class (all names are reserved): the constants
    # `DEVICE_NAME`, `VENDOR_NAME`, `VENDOR_ID`, `PRODUCT_ID`, `DISCRIMINATOR`,
    # `SETUP_PIN`, `PRIMARY_DEVICE_TYPE_ID`, `PRODUCT_APPEARANCE`,
    # `HARDWARE_VERSION`, `HARDWARE_VERSION_STRING`, `SOFTWARE_VERSION`,
    # `SOFTWARE_VERSION_STRING`, `SERIAL_NUMBER`, `UNIQUE_ID` and
    # `STORAGE_PATH`; the methods they back; `device_clusters`,
    # `endpoint_device_types`, `template_endpoint`, `dsl_wire_callbacks` and
    # one `dsl_template_<name>` per template; the `*_DECLS` accumulators.
    module DSL
      # `identity` keys that must be given, and the ones that may be.
      REQUIRED_IDENTITY = [:vendor, :product, :vendor_id, :product_id, :discriminator, :pin, :device_type]
      OPTIONAL_IDENTITY = [
        :appearance, :hardware_version, :hardware_version_string,
        :software_version, :software_version_string, :serial_number, :unique_id,
      ]

      # `network` kinds, as `{NetworkType member, Feature member}`.
      NETWORK_KINDS = {
        "ethernet" => {"Ethernet", "EthernetNetworkInterface"},
        "wifi"     => {"WiFi", "WiFiNetworkInterface"},
        "thread"   => {"Thread", "ThreadNetworkInterface"},
      }

      # The device's identity: what a controller shows and what the setup
      # payload, BasicInformation and mDNS advertisements carry.
      macro identity(**options)
        {% raise "#{@type}: `identity` declared twice" unless @type.constant("IDENTITY_DECLS").empty? %}
        {% known = ::Matter::Device::DSL::REQUIRED_IDENTITY + ::Matter::Device::DSL::OPTIONAL_IDENTITY %}
        {% for key, _value in options %}
          {% unless known.includes?(key.symbolize) %}
            {% raise "#{@type}: identity has an unknown option #{key} (expected one of #{known.join(", ").id})" %}
          {% end %}
        {% end %}
        {% for key in ::Matter::Device::DSL::REQUIRED_IDENTITY %}
          {% raise "#{@type}: identity needs #{key.id}:" if options[key].nil? %}
        {% end %}
        {% @type.constant("IDENTITY_DECLS") << options %}

        DEVICE_NAME            = ({{ options[:product] }}).to_s
        VENDOR_NAME            = ({{ options[:vendor] }}).to_s
        VENDOR_ID              = ({{ options[:vendor_id] }}).to_u16
        PRODUCT_ID             = ({{ options[:product_id] }}).to_u16
        DISCRIMINATOR          = ({{ options[:discriminator] }}).to_u16
        SETUP_PIN              = ({{ options[:pin] }}).to_u32
        PRIMARY_DEVICE_TYPE_ID = ({{ options[:device_type] }}).to_u32

        def device_name : String
          DEVICE_NAME
        end

        def product_name : String
          DEVICE_NAME
        end

        def vendor_name : String
          VENDOR_NAME
        end

        def vendor_id : UInt16
          VENDOR_ID
        end

        def product_id : UInt16
          PRODUCT_ID
        end

        def discriminator : UInt16
          DISCRIMINATOR
        end

        def setup_pin : UInt32
          SETUP_PIN
        end

        def primary_device_type_id : UInt32
          PRIMARY_DEVICE_TYPE_ID
        end

        {% if options[:appearance] %}
          PRODUCT_APPEARANCE = ::Matter::Cluster::BasicInformation::ProductAppearanceStruct.new({{ options[:appearance] }})

          def product_appearance : ::Matter::Cluster::BasicInformation::ProductAppearanceStruct?
            PRODUCT_APPEARANCE
          end
        {% end %}

        {% if options[:hardware_version] %}
          HARDWARE_VERSION = ({{ options[:hardware_version] }}).to_u16

          def hardware_version : UInt16
            HARDWARE_VERSION
          end
        {% end %}

        {% if options[:hardware_version_string] %}
          HARDWARE_VERSION_STRING = ({{ options[:hardware_version_string] }}).to_s

          def hardware_version_string : String
            HARDWARE_VERSION_STRING
          end
        {% end %}

        {% if options[:software_version] %}
          SOFTWARE_VERSION = ({{ options[:software_version] }}).to_u32

          def software_version : UInt32
            SOFTWARE_VERSION
          end
        {% end %}

        {% if options[:software_version_string] %}
          SOFTWARE_VERSION_STRING = ({{ options[:software_version_string] }}).to_s

          def software_version_string : String
            SOFTWARE_VERSION_STRING
          end
        {% end %}

        {% if options[:serial_number] %}
          SERIAL_NUMBER = ({{ options[:serial_number] }}).to_s

          def serial_number : String?
            SERIAL_NUMBER
          end
        {% end %}

        {% if options[:unique_id] %}
          UNIQUE_ID = ({{ options[:unique_id] }}).to_s

          def unique_id : String?
            UNIQUE_ID
          end
        {% end %}
      end

      # Where the device keeps its fabrics, sessions and cluster state.
      # `storage yaml: "device.yml"`, `storage json: "device.json"` or
      # `storage :memory`.
      macro storage(kind = nil, yaml = nil, json = nil)
        {% given = (kind ? 1 : 0) + (yaml ? 1 : 0) + (json ? 1 : 0) %}
        {% raise "#{@type}: storage takes exactly one of :memory, yaml: or json:" unless given == 1 %}
        {% if kind && kind.id.stringify != "memory" %}
          {% raise "#{@type}: storage #{kind} is not a backend (expected :memory, yaml: or json:)" %}
        {% end %}

        {% unless kind %}
          STORAGE_PATH = {{ yaml || json }}
        {% end %}

        {% if kind %}
          {% backend = "::Matter::Storage::Memory.new".id %}
        {% elsif yaml %}
          {% backend = "::Matter::Storage::YamlFile.new(STORAGE_PATH)".id %}
        {% else %}
          {% backend = "::Matter::Storage::JsonFile.new(STORAGE_PATH)".id %}
        {% end %}

        def initialize(
          storage : ::Matter::Storage::Backend = {{ backend }},
          ip_addresses : Array(Socket::IPAddress)? = nil,
          port : Int32 = ::Matter::Device::DEFAULT_PORT,
          hostname : String? = nil,
          max_fabrics : UInt8 = ::Matter::FabricTable::DEFAULT_MAX_FABRICS,
          network_backend : ::Matter::Network::Backend? = nil,
          tc_min_required_version : UInt16? = nil,
          tc_required_acknowledgements : UInt16 = 0_u16,
          icd_configuration : ::Matter::Cluster::IcdManagement::Configuration? = nil,
          regulatory_location_capability : ::Matter::Cluster::GeneralCommissioning::RegulatoryLocationType = ::Matter::Cluster::GeneralCommissioning::RegulatoryLocationType::IndoorOutdoor,
          tcp_enabled : Bool = false,
          groupcast_listener : Bool = false,
          groupcast_sender : Bool = false,
          groupcast_per_group : Bool = false,
          groupcast_max_mcast_addr_count : UInt16? = nil,
          on_restriction_review_requested : ::Matter::Device::RestrictionReviewRequested? = nil,
          on_restriction_review_updated : ::Matter::Device::RestrictionReviewUpdated? = nil,
        )
          super
        end
      end

      # Host-owned managed restriction review callbacks. Each method receives
      # the same token again if a crash interrupted durable completion.
      macro managed_restrictions(requested, updated)
        {% unless requested.is_a?(SymbolLiteral) && updated.is_a?(SymbolLiteral) %}
          {% raise "managed_restrictions requires requested: and updated: method symbols" %}
        {% end %}

        protected def default_restriction_review_requested : ::Matter::Device::RestrictionReviewRequested?
          ->(request : ::Matter::Cluster::AccessControl::RestrictionReviewRequest) { {{ requested.id }}(request) }
        end

        protected def default_restriction_review_updated : ::Matter::Device::RestrictionReviewUpdated?
          ->(fabric : UInt8, update : ::Matter::Cluster::AccessControl::FabricRestrictionReviewUpdate) do
            {{ updated.id }}(fabric, update)
          end
        end
      end

      # The network the device commissions over: `:ethernet` (the default),
      # `:wifi` or `:thread`.
      macro network(kind)
        {% members = ::Matter::Device::DSL::NETWORK_KINDS[kind.id.stringify] %}
        {% unless members %}
          {% raise "#{@type}: network #{kind} is unknown (expected one of #{::Matter::Device::DSL::NETWORK_KINDS.keys.join(", ").id})" %}
        {% end %}

        protected def commissioning_network_type : ::Matter::Cluster::NetworkCommissioning::NetworkType
          ::Matter::Cluster::NetworkCommissioning::NetworkType::{{ members[0].id }}
        end

        protected def commissioning_network_feature_map : ::Matter::Cluster::NetworkCommissioning::Feature
          ::Matter::Cluster::NetworkCommissioning::Feature::{{ members[1].id }}
        end
      end

      # One endpoint of the device and the clusters it serves.
      macro endpoint(number, device_type, parent_endpoint = nil, tag_list = nil, &block)
        {% raise "#{@type}: endpoint #{number} device_type: takes one device type id" if device_type.is_a?(ArrayLiteral) %}
        {% if @type.constant("ENDPOINT_DECLS").any? { |decl| decl[:kind] == :endpoint && decl[:number] == number } %}
          {% raise "#{@type}: endpoint #{number} declared twice" %}
        {% end %}
        {% @type.constant("ENDPOINT_DECLS") << {kind: :endpoint, number: number, name: nil, device_type: device_type, parameters: nil, parent_endpoint: parent_endpoint, tag_list: tag_list} %}
        {% if block %}
          {{ block.body }}
        {% end %}
      end

      # The shape of an endpoint the device adds at runtime with
      # `add_endpoint(:name, **parameters)`.
      macro endpoint_template(name, device_type, parameters = nil, tag_list = nil, &block)
        {% raise "#{@type}: endpoint_template :#{name.id} needs a name symbol" unless name.is_a?(SymbolLiteral) %}
        {% if parameters && !parameters.is_a?(NamedTupleLiteral) %}
          {% raise "#{@type}: endpoint_template :#{name.id} parameters: must be a {name: Type} literal" %}
        {% end %}
        {% if @type.constant("ENDPOINT_DECLS").any? { |decl| decl[:kind] == :template && decl[:name] == name } %}
          {% raise "#{@type}: endpoint_template :#{name.id} declared twice" %}
        {% end %}
        {% @type.constant("ENDPOINT_DECLS") << {kind: :template, number: nil, name: name, device_type: device_type, parameters: parameters, parent_endpoint: nil, tag_list: tag_list} %}
        {% if block %}
          {{ block.body }}
        {% end %}
      end

      # One cluster of the enclosing `endpoint` or `endpoint_template`, built
      # as `Klass.new(endpoint_number, *args, **options)`.
      macro cluster(klass, *args, **options)
        {% scope = @type.constant("ENDPOINT_DECLS").size - 1 %}
        {% raise "#{@type}: cluster #{klass} must be declared inside an endpoint or endpoint_template block" if scope < 0 %}
        {% if options[:as] %}
          {% raise "#{@type}: cluster #{klass} as: must be a symbol" unless options[:as].is_a?(SymbolLiteral) %}
          {% if @type.constant("ENDPOINT_DECLS")[scope][:kind] == :template %}
            {% raise "#{@type}: cluster #{klass} as: names a single instance, which a template has not; read it from the endpoint add_endpoint returns" %}
          {% end %}
          {% if @type.constant("CLUSTER_DECLS").any? { |decl| decl[:as] == options[:as] } %}
            {% raise "#{@type}: cluster accessor :#{options[:as].id} declared twice" %}
          {% end %}
        {% end %}
        {% @type.constant("CLUSTER_DECLS") << {scope: scope, klass: klass, args: args, options: options, as: options[:as]} %}
      end

      # Advertise an outbound client cluster on the enclosing endpoint.
      # The ID is placed in Descriptor.ClientList; it does not create a server.
      macro client_cluster(id)
        {% scope = @type.constant("ENDPOINT_DECLS").size - 1 %}
        {% raise "#{@type}: client_cluster must be declared inside an endpoint block" if scope < 0 %}
        {% @type.constant("CLIENT_CLUSTER_DECLS") << {scope: scope, id: id} %}
      end

      # Installs *block* as the `on_<event>` callback of the cluster declared
      # `as: :accessor`.
      macro on(accessor, event, &block)
        {% raise "#{@type}: on(:#{accessor.id}, :#{event.id}) needs a block" unless block %}
        {% @type.constant("CALLBACK_DECLS") << {accessor: accessor, event: event, args: block.args, body: block.body} %}
      end

      # Turns the declarations into code; called once the class body is
      # complete (see `Device.inherited`).
      macro dsl_generate
        {% endpoints = @type.constant("ENDPOINT_DECLS") %}
        {% cluster_decls = @type.constant("CLUSTER_DECLS") %}
        {% client_cluster_decls = @type.constant("CLIENT_CLUSTER_DECLS") %}
        {% callbacks = @type.constant("CALLBACK_DECLS") %}
        {% statics = endpoints.select { |decl| decl[:kind] == :endpoint } %}
        {% templates = endpoints.select { |decl| decl[:kind] == :template } %}

        {% for decl in cluster_decls %}
          {% if decl[:as] %}
            getter! {{ decl[:as].id }} : {{ decl[:klass] }}
          {% end %}
        {% end %}

        {% unless endpoints.empty? && callbacks.empty? %}
          {% if @type.methods.any? { |method| method.name == "device_clusters" } %}
            {% raise "#{@type}: device_clusters is generated from the endpoint declarations; remove one of the two" %}
          {% end %}

          protected def device_clusters : Array(::Matter::Cluster::Base)
            built = [] of ::Matter::Cluster::Base
            {% for decl, index in endpoints %}
              {% if decl[:kind] == :endpoint %}
                {% own = cluster_decls.select { |cluster| cluster[:scope] == index } %}
                {% unless own.empty? %}
                  %endpoint{index} = ::Matter::DataType::EndpointNumber.new(({{ decl[:number] }}).to_u16)
                  {% for cluster in own %}
                    {% if cluster[:as] %}
                      @{{ cluster[:as].id }} = {{ cluster[:klass] }}.new(%endpoint{index}{% for argument in cluster[:args] %}, {{ argument }}{% end %}{% for key, value in cluster[:options] %}{% unless key.symbolize == :as %}, {{ key }}: {{ value }}{% end %}{% end %})
                      built << {{ cluster[:as].id }}
                    {% else %}
                      built << {{ cluster[:klass] }}.new(%endpoint{index}{% for argument in cluster[:args] %}, {{ argument }}{% end %}{% for key, value in cluster[:options] %}{% unless key.symbolize == :as %}, {{ key }}: {{ value }}{% end %}{% end %})
                    {% end %}
                  {% end %}
                {% end %}
              {% end %}
            {% end %}
            dsl_wire_callbacks
            built
          end

          # Installs the `on` callbacks. Called once every endpoint has been
          # built, so a callback may reference any accessor.
          private def dsl_wire_callbacks : Nil
            {% for callback in callbacks %}
              {{ callback[:accessor].id }}.on_{{ callback[:event].id }} do {% unless callback[:args].empty? %}|{{ callback[:args].splat }}|{% end %}
                {{ callback[:body] }}
              end
            {% end %}
          end
        {% end %}

        {% unless statics.empty? %}
          protected def endpoint_compositions : Hash(UInt16, Tuple(UInt16, Array(::Matter::Cluster::Descriptor::SemanticTag)))
            compositions = {} of UInt16 => Tuple(UInt16, Array(::Matter::Cluster::Descriptor::SemanticTag))
            {% for decl in statics %}
              compositions[({{ decl[:number] }}).to_u16] = {
                {% if decl[:parent_endpoint] %}({{ decl[:parent_endpoint] }}).to_u16{% else %}0_u16{% end %},
                {% if decl[:tag_list] %}{{ decl[:tag_list] }}{% else %}[] of ::Matter::Cluster::Descriptor::SemanticTag{% end %},
              }
            {% end %}
            compositions
          end

          protected def endpoint_client_clusters : Hash(UInt16, Array(UInt32))
            clients = {} of UInt16 => Array(UInt32)
            {% for decl, index in endpoints %}
              {% if decl[:kind] == :endpoint %}
                clients[({{ decl[:number] }}).to_u16] = [
                  {% for client in client_cluster_decls.select { |entry| entry[:scope] == index } %}
                    ({{ client[:id] }}).to_u32,
                  {% end %}
                ] of UInt32
              {% end %}
            {% end %}
            clients
          end

          {% if @type.methods.any? { |method| method.name == "endpoint_device_types" } %}
            {% raise "#{@type}: endpoint_device_types is generated from the endpoint declarations; remove one of the two" %}
          {% end %}

          protected def endpoint_device_types : Hash(UInt16, UInt32)
            {
              {% for decl in statics %}
                ({{ decl[:number] }}).to_u16 => ({{ decl[:device_type] }}).to_u32,
              {% end %}
            }
          end
        {% end %}

        {% unless templates.empty? %}
          protected def template_tags(template : String) : Array(::Matter::Cluster::Descriptor::SemanticTag)
            case template
            {% for decl in templates %}
              when {{ decl[:name].id.stringify }}
                {% if decl[:tag_list] %}{{ decl[:tag_list] }}{% else %}[] of ::Matter::Cluster::Descriptor::SemanticTag{% end %}
            {% end %}
            else
              super
            end
          end

          {% for decl, index in endpoints %}
            {% if decl[:kind] == :template %}
              private def dsl_template_clients_{{ decl[:name].id }} : Array(UInt32)
                [
                  {% for client in client_cluster_decls.select { |entry| entry[:scope] == index } %}
                    ({{ client[:id] }}).to_u32,
                  {% end %}
                ] of UInt32
              end

              private def dsl_template_{{ decl[:name].id }}(
                endpoint_id : UInt16,
                parameters : ::Matter::Storage::Document,
              ) : Array(::Matter::Cluster::Base)
                {% if decl[:parameters] %}
                  {% for name, type in decl[:parameters] %}
                    {{ name.id }} = template_parameter(parameters, {{ name.id.stringify }}, {{ type }})
                  {% end %}
                {% end %}
                %endpoint = ::Matter::DataType::EndpointNumber.new(endpoint_id)
                built = [] of ::Matter::Cluster::Base
                {% for cluster in cluster_decls.select { |entry| entry[:scope] == index } %}
                  built << {{ cluster[:klass] }}.new(%endpoint{% for argument in cluster[:args] %}, {{ argument }}{% end %}{% for key, value in cluster[:options] %}, {{ key }}: {{ value }}{% end %})
                {% end %}
                built
              end
            {% end %}
          {% end %}

          protected def template_endpoint(
            template : String,
            endpoint_id : UInt16,
            parameters : ::Matter::Storage::Document,
          ) : Tuple(Array(::Matter::Cluster::Base), Array(UInt32), Array(UInt32))
            case template
            {% for decl in templates %}
              when {{ decl[:name].id.stringify }}
                {
                  dsl_template_{{ decl[:name].id }}(endpoint_id, parameters),
                  {% if decl[:device_type].is_a?(ArrayLiteral) %}
                    [{% for id in decl[:device_type] %}({{ id }}).to_u32,{% end %}] of UInt32,
                  {% else %}
                    [({{ decl[:device_type] }}).to_u32] of UInt32,
                  {% end %}
                  dsl_template_clients_{{ decl[:name].id }},
                }
            {% end %}
            else
              super
            end
          end
        {% end %}
      end
    end
  end
end
