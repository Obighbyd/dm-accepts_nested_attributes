module DataMapper
  module NestedAttributes
    class Assignment
      include Assertions

      attr_reader :acceptor
      attr_reader :relationship
      attr_reader :assignee

      def self.for_collection(acceptor, assignee)
        Assignment::Collection.new(acceptor, assignee)
      end

      def self.for_resource(acceptor, assignee)
        Assignment::Resource.new(acceptor, assignee)
      end

      # @param [DataMapper::Associations::Relationship] relationship
      #   The relationship backing the association.
      #   Assignment will happen on the target end of the relationship
      #
      def initialize(acceptor, assignee)
        @acceptor     = acceptor
        @relationship = acceptor.relationship
        @assignee     = assignee
      end

      def assign(attributes)
        raise NotImplementedError, "#{self.class}#assign is not implemented"
      end

      # Extracts the primary key values necessary to retrieve or update a nested
      # model when using +accepts_nested_attributes_for+. Values are taken from
      # +assignee+ and the given attribute hash with the former having priority.
      # Values for properties in the primary key that are *not* included in the
      # foreign key must be specified in the attributes hash.
      #
      # @param [Hash{Symbol => Object}] attributes
      #   The attributes assigned to the nested attribute setter on the
      #   +model+.
      #
      # @return [Array]
      def extract_keys(attributes)
        relationship.extract_keys_for_nested_attributes(assignee, attributes)
      end

      # Updates a record with the +attributes+ or marks it for destruction if
      # the +:allow_destroy+ option is +true+ and {#has_delete_flag?} returns
      # +true+.
      #
      # @param [DataMapper::Resource] resource
      #   The resource to be updated or destroyed
      #
      # @param [Hash{Symbol => Object}] attributes
      #   The attributes to assign to the relationship's target end.
      #   All attributes except {#unupdatable_keys} will be assigned.
      #
      # @return [void]
      def update_or_mark_as_destroyable(resource, attributes)
        if acceptor.has_delete_flag?(attributes) && acceptor.allow_destroy?
          mark_as_destroyable(resource)
        else
          update(resource, attributes)
        end
      end

      def update(resource, attributes)
        assert_nested_update_clean_only(resource)
        resource.attributes = updatable_attributes(resource, attributes)
        resource.save
      end

      def mark_as_destroyable(resource)
        mark_intermediaries_as_destroyable(resource) if acceptor.many_to_many?
        destroyables << resource
      end

      def mark_intermediaries_as_destroyable(resource)
        intermediary_collection = relationship.through.get(assignee)
        intermediaries = intermediary_collection.all(relationship.via => resource)
        intermediaries.each { |intermediary| destroyables << intermediary }
      end

      def destroyables
        assignee.__send__(:destroyables)
      end

      def creatable_attributes(resource, attributes)
        DataMapper::Ext::Hash.except(attributes, *uncreatable_keys(resource))
      end

      def updatable_attributes(resource, attributes)
        DataMapper::Ext::Hash.except(attributes, *unupdatable_keys(resource))
      end

      # Attribute hash keys that are excluded when creating a nested resource.
      # Excluded attributes include +:_delete+, a special value used to mark a
      # resource for destruction.
      #
      # @return [Array<Symbol>] Excluded attribute names.
      def uncreatable_keys(resource)
        acceptor.uncreatable_keys(resource)
      end

      def unupdatable_keys(resource)
        acceptor.unupdatable_keys(resource)
      end

      # Raises an exception if the specified resource is dirty or has dirty
      # children.
      #
      # @param [DataMapper::Resource] resource
      #   The resource to check.
      #
      # @return [void]
      #
      # @raise [UpdateConflictError]
      #   If the resource is dirty.
      #
      # @api private
      def assert_nested_update_clean_only(resource)
        if resource.send(:dirty_self?) || resource.send(:dirty_children?)
          new_or_dirty = resource.new? ? 'new' : 'dirty'
          raise UpdateConflictError, "#{resource.model}#update cannot be called on a #{new_or_dirty} nested resource"
        end
      end

      class Resource < Assignment
        # Assigns the given attributes to the resource association.
        #
        # If the given attributes include the primary key values that match the
        # existing record’s keys, then the existing record will be modified.
        # Otherwise a new record will be built.
        #
        # If the given attributes include matching primary key values _and_ a
        # <tt>:_delete</tt> key set to a truthy value, then the existing record
        # will be marked for destruction.
        #
        # The names of the primary key values required depend on the configuration
        # of the association. It is not necessary to specify values for attributes
        # that exist on this resource as they are inferred.
        #
        # @param [Hash{Symbol => Object}] attributes
        #   The attributes to assign to the relationship's target end.
        #   All attributes except {#uncreatable_keys} (for new resources) and
        #   {#unupdatable_keys} (when updating an existing resource) will be
        #   assigned.
        #
        # @return [void]
        def assign(attributes)
          assert_kind_of 'attributes', attributes, Hash

          if keys = extract_keys(attributes)
            if existing_resource = existing_resource_for_key(keys)
              update_or_mark_as_destroyable(existing_resource, attributes)
              return self
            end
          end

          return self if acceptor.reject_new_record?(assignee, attributes)

          assign_new_resource(attributes)
        end

        def existing_resource_for_key(key)
          existing_related = relationship.get(assignee)
          existing_related if existing_related && existing_related.key == key
        end

        def assign_new_resource(attributes)
          new_resource = relationship.target_model.new
          new_resource.attributes = creatable_attributes(new_resource, attributes)
          relationship.set(assignee, new_resource)
        end
      end # class Resource

      class Collection < Assignment::Resource
        # Assigns the given attributes to the collection association.
        #
        # Hashes with primary key values matching an existing associated record
        # will update that record. Hashes without primary key values (or only
        # values for a partial primary key), or if no existing associated record
        # exists, will build a new record for the association. Hashes with
        # matching primary key values and a <tt>:_delete</tt> key set to a truthy
        # value will mark the matched record for destruction.
        #
        # The names of the primary key values required depend on the configuration
        # of the association. It is not necessary to specify values for attributes
        # that exist on this resource as they are inferred.
        #
        # For example:
        #
        #     assign_nested_attributes_for_collection_association(:people, {
        #       '1' => { :id => '1', :name => 'Peter' },
        #       '2' => { :name => 'John' },
        #       '3' => { :id => '2', :_delete => true }
        #     })
        #
        # Will update the name of the Person with ID 1, build a new associated
        # person with the name 'John', and mark the associatied Person with ID 2
        # for destruction.
        #
        #     assign_nested_attributes_for_collection_association(:people, {
        #       '1' => { :person_id => '1', :audit_id => 2, :name => 'Peter' },
        #       '2' => { :audit_id => 2, :name => 'John' },
        #       '3' => { :person_id => '2', :audit_id => 3, :_delete => true }
        #     })
        #
        # Will update the name of the Person with `(person_id, audit_id) = (1, 2)`,
        # build a new associated person with the name 'John', and mark the
        # associatied Person with key `(2, 3)` for destruction.
        #
        # Also accepts an Array of attribute hashes:
        #
        #     assign_nested_attributes_for_collection_association(:people, [
        #       { :id => '1', :name => 'Peter' },
        #       { :name => 'John' },
        #       { :id => '2', :_delete => true }
        #     ])
        #
        # @param [Hash{Integer=>Hash}, Array<Hash>] attributes
        #   The attributes to assign to the relationship's target end.
        #   All attributes except {#uncreatable_keys} (for new resources) and
        #   {#unupdatable_keys} (when updating an existing resource) will be
        #   assigned.
        #
        # @return [void]
        def assign(attributes)
          assert_hash_or_array_of_hashes("attributes", attributes)

          attributes_collection = normalize_attributes_collection(attributes)
          attributes_collection.each do |attributes|
            super(attributes)
          end

          self
        end

        def existing_resource_for_key(key)
          collection.get(*key)
        end

        def assign_new_resource(attributes)
          new_resource = collection.new(attributes)
          new_resource.attributes = creatable_attributes(new_resource, attributes)
          new_resource
        end

        def collection
          relationship.get(assignee)
        end

        # Make sure to return a collection of attribute hashes.
        # If passed an attributes hash, map it to its attributes.
        #
        # @param attributes [Hash, #each]
        #   An attributes hash or a collection of attribute hashes.
        #
        # @return [#each]
        #   A collection of attribute hashes.
        def normalize_attributes_collection(attributes)
          if attributes.is_a?(Hash)
            attributes.map { |_, attrs| attrs }
          else
            attributes
          end
        end

        # Asserts that the specified parameter value is a Hash of Hashes, or an
        # Array of Hashes and raises an ArgumentError if value does not conform.
        #
        # @param [String] param_name
        #   The parameter name included in the raised ArgumentError.
        #
        # @param value
        #   The value to check.
        #
        # @return [void]
        def assert_hash_or_array_of_hashes(param_name, value)
          case value
          when Hash
            unless value.values.all? { |a| a.is_a?(Hash) }
              raise ArgumentError,
                    "+#{param_name}+ should be a Hash of Hashes or Array " +
                    "of Hashes, but was a Hash with #{value.values.map { |a| a.class }.uniq.inspect}"
            end
          when Array
            unless value.all? { |a| a.is_a?(Hash) }
              raise ArgumentError,
                    "+#{param_name}+ should be a Hash of Hashes or Array " +
                    "of Hashes, but was an Array with #{value.map { |a| a.class }.uniq.inspect}"
            end
          else
            raise ArgumentError,
                  "+#{param_name}+ should be a Hash of Hashes or Array of " +
                  "Hashes, but was #{value.class}"
          end
        end

      end # class Collection

    end # class Assignment
  end # module NestedAttributes
end # module DataMapper
