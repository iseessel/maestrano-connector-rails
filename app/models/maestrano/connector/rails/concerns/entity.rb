module Maestrano::Connector::Rails::Concerns::Entity
  extend ActiveSupport::Concern

  def initialize(organization, connec_client, external_client, opts={})
    @organization = organization
    @connec_client = connec_client
    @external_client = external_client
    @opts = opts
  end

  module ClassMethods
    # ----------------------------------------------
    #                 IdMap methods
    # ----------------------------------------------
    def names_hash
      {
        connec_entity: connec_entity_name.downcase,
        external_entity: external_entity_name.downcase
      }
    end

    # organization_and_id can be either:
    # * {connec_id: 'id', organization_id: 'id'}
    # * {external_id: 'id', organization_id: 'id'}
    # Needs to include either connec_entity or external_entity for complex entities
    def find_or_create_idmap(organization_and_id)
      Maestrano::Connector::Rails::IdMap.find_or_create_by(names_hash.merge(organization_and_id))
    end
    def find_idmap(organization_and_id)
      Maestrano::Connector::Rails::IdMap.find_by(names_hash.merge(organization_and_id))
    end
    def create_idmap(organization_and_id)
      Maestrano::Connector::Rails::IdMap.create(names_hash.merge(organization_and_id))
    end

    # ----------------------------------------------
    #              Connec! methods
    # ----------------------------------------------
    def normalized_connec_entity_name
      normalize_connec_entity_name(connec_entity_name)
    end

    def normalize_connec_entity_name(name)
      if singleton?
        name.parameterize('_')
      else
        name.parameterize('_').pluralize
      end
    end

    # ----------------------------------------------
    #             External methods
    # ----------------------------------------------
    def id_from_external_entity_hash(entity)
      raise "Not implemented"
    end

    def last_update_date_from_external_entity_hash(entity)
      raise "Not implemented"
    end

    # Return a string representing the object from a connec! entity hash
    def object_name_from_connec_entity_hash(entity)
      raise "Not implemented"
    end

    # Return a string representing the object from an external entity hash
    def object_name_from_external_entity_hash(entity)
      raise "Not implemented"
    end

    # Returns a boolean
    # Returns true is the entity is flagged as inactive (deleted) in the external application
    def inactive_from_external_entity_hash?(entity)
      false
    end
    # ----------------------------------------------
    #             Entity specific methods
    # Those methods need to be define in each entity
    # ----------------------------------------------
    # Is this resource a singleton (in Connec!)?
    def singleton?
      false
    end

    # Entity name in Connec!
    def connec_entity_name
      raise "Not implemented"
    end

    # Entity name in external system
    def external_entity_name
      raise "Not implemented"
    end

    # Entity Mapper Class
    def mapper_class
      raise "Not implemented"
    end

    # An array of connec fields that are references
    def references
      []
    end

    def can_read_connec?
      can_write_external?
    end

    def can_read_external?
      can_write_connec?
    end

    def can_write_connec?
      true
    end

    def can_write_external?
      true
    end

    def can_update_external?
      true
    end
  end

  # ----------------------------------------------
  #                 Mapper methods
  # ----------------------------------------------
  # Map a Connec! entity to the external model
  def map_to_external(entity)
    connec_id = entity[:__connec_id]
    mapped_entity = self.class.mapper_class.normalize(entity)
    connec_id ? mapped_entity.merge(__connec_id: connec_id) : mapped_entity
  end

  # Map an external entity to Connec! model
  def map_to_connec(entity)
    mapped_entity = self.class.mapper_class.denormalize(entity)
    Maestrano::Connector::Rails::ConnecHelper.fold_references(mapped_entity, self.class.references, @organization)
  end

  # ----------------------------------------------
  #                 Connec! methods
  # ----------------------------------------------
  # Supported options:
  # * full_sync
  # * $filter (see Connec! documentation)
  # * $orderby (see Connec! documentation)
  def get_connec_entities(last_synchronization)
    return [] unless self.class.can_read_connec?

    @connec_client.class.headers('CONNEC-EXTERNAL-IDS' => true)

    Maestrano::Connector::Rails::ConnectorLogger.log('info', @organization, "Fetching Connec! #{self.class.connec_entity_name}")

    entities = []
    query_params = {}
    query_params[:$orderby] = @opts[:$orderby] if @opts[:$orderby]

    # Fetch first page
    page_number = 0
    if last_synchronization.blank? || @opts[:full_sync]
      Maestrano::Connector::Rails::ConnectorLogger.log('debug', @organization, "entity=#{self.class.connec_entity_name}, fetching all data")
      query_params[:$filter] = @opts[:$filter] if @opts[:$filter]
    else
      Maestrano::Connector::Rails::ConnectorLogger.log('debug', @organization, "entity=#{self.class.connec_entity_name}, fetching data since #{last_synchronization.updated_at.iso8601}")
      query_params[:$filter] = "updated_at gt '#{last_synchronization.updated_at.iso8601}'" + (@opts[:$filter] ? " and #{@opts[:$filter]}" : '')
    end

    uri = "/#{self.class.normalized_connec_entity_name}?#{query_params.to_query}"
    response_hash = fetch_connec(uri, 0)
    entities = response_hash["#{self.class.normalized_connec_entity_name}"]

    # Fetch subsequent pages
    while response_hash['pagination'] && response_hash['pagination']['next']
      page_number += 1
      # ugly way to convert https://api-connec/api/v2/group_id/organizations?next_page_params to /organizations?next_page_params
      next_page = response_hash['pagination']['next'].gsub(/^(.*)\/#{self.class.normalized_connec_entity_name}/, self.class.normalized_connec_entity_name)

      response_hash = fetch_connec(uri, page_number)
      entities << response_hash["#{self.class.normalized_connec_entity_name}"]
    end

    entities.flatten!
    Maestrano::Connector::Rails::ConnectorLogger.log('info', @organization, "Received data: Source=Connec!, Entity=#{self.class.connec_entity_name}, Data=#{entities}")
    entities
  end

  def push_entities_to_connec(mapped_external_entities_with_idmaps)
    push_entities_to_connec_to(mapped_external_entities_with_idmaps, self.class.connec_entity_name)
  end

  def push_entities_to_connec_to(mapped_external_entities_with_idmaps, connec_entity_name)
    return unless self.class.can_write_connec?

    Maestrano::Connector::Rails::ConnectorLogger.log('info', @organization, "Sending #{Maestrano::Connector::Rails::External.external_name} #{self.class.external_entity_name.pluralize} to Connec! #{connec_entity_name.pluralize}")
    
    request_per_call = @opts[:request_per_batch_call] || 100
    start = 0
    while start < mapped_external_entities_with_idmaps.size
      # Prepare batch request
      batch_entities = mapped_external_entities_with_idmaps.slice(start, request_per_call)
      batch_request = {sequential: true, ops: []}

      batch_entities.each do |mapped_external_entity_with_idmap|
        mapped_external_entity = mapped_external_entity_with_idmap[:entity]
        batch_request[:ops] << batch_op('post', mapped_external_entity, nil, self.class.normalize_connec_entity_name(connec_entity_name))
      end

      # Batch call
      Maestrano::Connector::Rails::ConnectorLogger.log('info', @organization, "Sending batch request to Connec! for #{self.class.normalize_connec_entity_name(connec_entity_name)}. Batch_request_size: #{batch_request[:ops].size}. Call_number: #{(start/request_per_call) + 1}")
      response = @connec_client.batch(batch_request)
      Maestrano::Connector::Rails::ConnectorLogger.log('debug', @organization, "Received batch response from Connec! for #{self.class.normalize_connec_entity_name(connec_entity_name)}: #{response}")
      raise "No data received from Connec! when trying to send batch request for #{self.class.connec_entity_name.pluralize}" unless response && !response.body.blank?
      response = JSON.parse(response.body)

      # Parse barch response
      response['results'].each_with_index do |result, index|
        if [200, 201].include?(result['status'])
          batch_entities[index][:idmap].update_attributes(last_push_to_connec: Time.now, message: nil)
        else
          Maestrano::Connector::Rails::ConnectorLogger.log('error', @organization, "Error while pushing to Connec!: #{result['body']}")
          batch_entities[index][:idmap].update_attributes(message: result['body'].truncate(255))
        end
      end
      start += request_per_call
    end
  end

  def batch_op(method, mapped_external_entity, id, connec_entity_name)
    Maestrano::Connector::Rails::ConnectorLogger.log('info', @organization, "Sending #{method.upcase} #{connec_entity_name}: #{mapped_external_entity} to Connec! (Preparing batch request)")
    {
      method: method,
      url: "/api/v2/#{@organization.uid}/#{connec_entity_name}/#{id}", # id should be nil for POST
      params: {
        "#{connec_entity_name}".to_sym => mapped_external_entity
      }
    }
  end

  # ----------------------------------------------
  #                 External methods
  # ----------------------------------------------
  def get_external_entities(last_synchronization)
    return [] unless self.class.can_read_external?
    Maestrano::Connector::Rails::ConnectorLogger.log('info', @organization, "Fetching #{Maestrano::Connector::Rails::External.external_name} #{self.class.external_entity_name.pluralize}")
    raise "Not implemented"
  end

  def push_entities_to_external(mapped_connec_entities_with_idmaps)
    push_entities_to_external_to(mapped_connec_entities_with_idmaps, self.class.external_entity_name)
  end

  def push_entities_to_external_to(mapped_connec_entities_with_idmaps, external_entity_name)
    return unless self.class.can_write_external?
    Maestrano::Connector::Rails::ConnectorLogger.log('info', @organization, "Sending Connec! #{self.class.connec_entity_name.pluralize} to #{Maestrano::Connector::Rails::External.external_name} #{external_entity_name.pluralize}")
    ids_to_send_to_connec = []
    mapped_connec_entities_with_idmaps.each do |mapped_connec_entity_with_idmap|
      push_entity_to_external(mapped_connec_entity_with_idmap, external_entity_name, ids_to_send_to_connec)
    end

    request_per_call = @opts[:request_per_batch_call] || 100
    start = 0
    while start < ids_to_send_to_connec.size
      # Prepare batch request
      batch_entities = ids_to_send_to_connec.slice(start, request_per_call)
      batch_request = {sequential: true, ops: []}

      batch_entities.each do |id|
        data = Maestrano::Connector::Rails::ConnecHelper.id_hash(id[:external_id], @organization)
        batch_request[:ops] << batch_op('put', data, id[:connec_id], self.class.normalize_connec_entity_name(self.class.connec_entity_name))
      end

      # Batch call
      # Maestrano::Connector::Rails::ConnectorLogger.log('info', @organization, "Sending batch request to Connec! for #{self.class.normalize_connec_entity_name(connec_entity_name)}. Batch_request_size: #{batch_request[:ops].size}. Call_number: #{(start/request_per_call) + 1}")
      response = @connec_client.batch(batch_request)
      # Maestrano::Connector::Rails::ConnectorLogger.log('debug', @organization, "Received batch response from Connec! for #{self.class.normalize_connec_entity_name(connec_entity_name)}: #{response}")
      raise "No data received from Connec! when trying to send batch request for #{self.class.connec_entity_name.pluralize}" unless response && !response.body.blank?
      response = JSON.parse(response.body)

      # Parse barch response
      response['results'].each_with_index do |result, index|
        if ![200, 201].include?(result['status'])
          # raise
          Maestrano::Connector::Rails::ConnectorLogger.log('error', @organization, "Error while pushing to Connec!: #{result['body']}")
        end
      end
      start += request_per_call
    end
  end

  def push_entity_to_external(mapped_connec_entity_with_idmap, external_entity_name, ids_to_send_to_connec)
    idmap = mapped_connec_entity_with_idmap[:idmap]
    mapped_connec_entity = mapped_connec_entity_with_idmap[:entity]

    begin
      if idmap.external_id.blank?
        connec_id = mapped_connec_entity.delete(:__connec_id)
        external_id = create_external_entity(mapped_connec_entity, external_entity_name)
        idmap.update(external_id: external_id, last_push_to_external: Time.now, message: nil)
        ids_to_send_to_connec << {connec_id: connec_id, external_id: external_id}
      else
        return unless self.class.can_update_external?
        update_external_entity(mapped_connec_entity, idmap.external_id, external_entity_name)
        if self.class.singleton? && idmap.last_push_to_external.nil?
          connec_id = mapped_connec_entity.delete(:__connec_id)
          ids_to_send_to_connec << {connec_id: connec_id, external_id: idmap.external_id}
        end
        idmap.update(last_push_to_external: Time.now, message: nil)
      end
    rescue => e
      # Store External error
      Maestrano::Connector::Rails::ConnectorLogger.log('error', @organization, "Error while pushing to #{Maestrano::Connector::Rails::External.external_name}: #{e}")
      idmap.update(message: e.message.truncate(255))
    end
  end

  def create_external_entity(mapped_connec_entity, external_entity_name)
    Maestrano::Connector::Rails::ConnectorLogger.log('info', @organization, "Sending create #{external_entity_name}: #{mapped_connec_entity} to #{Maestrano::Connector::Rails::External.external_name}")
    raise "Not implemented"
  end

  def update_external_entity(mapped_connec_entity, external_id, external_entity_name)
    Maestrano::Connector::Rails::ConnectorLogger.log('info', @organization, "Sending update #{external_entity_name} (id=#{external_id}): #{mapped_connec_entity} to #{Maestrano::Connector::Rails::External.external_name}")
    raise "Not implemented"
  end

  # This method is called during the webhook workflow only. It should return the array of filtered entities
  # The aim is to have the same filtering as with the Connec! filters on API calls in the webhooks
  def filter_connec_entities(entities)
    entities
  end

  # ----------------------------------------------
  #                 General methods
  # ----------------------------------------------
  # * Discards entities that do not need to be pushed because they have not been updated since their last push
  # * Discards entities from one of the two source in case of conflict
  # * Maps not discarded entities and associates them with their idmap, or create one if there isn't any
  # * Returns a hash {connec_entities: [], external_entities: []}
  def consolidate_and_map_data(connec_entities, external_entities)
    return consolidate_and_map_singleton(connec_entities, external_entities) if self.class.singleton?

    idmaps = {}
    mapped_connec_entities = consolidate_and_map_connec_entities(connec_entities, external_entities, idmaps)
    mapped_external_entities = consolidate_and_map_external_entities(external_entities, idmaps)

    return {connec_entities: mapped_connec_entities, external_entities: mapped_external_entities}
  end

  def consolidate_and_map_connec_entities(connec_entities, external_entities, idmaps)
    connec_entities.map{|entity|
      entity = Maestrano::Connector::Rails::ConnecHelper.unfold_references(entity, self.class.references, @organization)
      next nil unless entity

      if entity['id'].blank?
        idmap = self.class.create_idmap(organization_id: @organization.id, name: self.class.object_name_from_connec_entity_hash(entity))
        next map_connec_entity_with_idmap(entity, self.class.external_entity_name, idmap)
      end

      idmap = self.class.find_or_create_idmap(external_id: entity['id'], organization_id: @organization.id)
      idmaps[entity['id']] = idmap
      idmap.update(name: self.class.object_name_from_connec_entity_hash(entity))

      next nil if idmap.external_inactive || !idmap.to_external || self.class.not_modified_since_last_push_to_external?(idmap, entity, self, @organization)

      # Check for conflict with entities from external
      self.class.solve_conflict(entity, self, external_entities, self.class.connec_entity_name, idmap, @organization, @opts)
    }.compact
  end

  def consolidate_and_map_external_entities(external_entities, idmaps)
    external_entities.map{|entity|
      entity_id = self.class.id_from_external_entity_hash(entity)
      idmap = idmaps[entity_id] || self.class.find_or_create_idmap({external_id: entity_id, organization_id: @organization.id})

      # Not pushing entity to Connec!
      next nil unless idmap.to_connec

      # Not pushing to Connec! and flagging as inactive if inactive in external application
      inactive = self.class.inactive_from_external_entity_hash?(entity)
      idmap.update(external_inactive: inactive, name: self.class.object_name_from_external_entity_hash(entity))
      next nil if inactive

      # Entity has not been modified since its last push to connec!
      next nil if self.class.not_modified_since_last_push_to_connec?(idmap, entity, self, @organization)

      {entity: map_to_connec(entity), idmap: idmap}
    }.compact
  end

  def consolidate_and_map_singleton(connec_entities, external_entities)
    return {connec_entities: [], external_entities: []} if external_entities.empty? && connec_entities.empty?

    idmap = self.class.find_or_create_idmap({organization_id: @organization.id})
    # No to_connec, to_external and inactive consideration here as we don't expect those workflow for singleton

    if external_entities.empty?
      keep_external = false
    elsif connec_entities.empty?
      keep_external = true
    elsif @opts.has_key?(:connec_preemption)
      keep_external = !@opts[:connec_preemption]
    else
      keep_external = !self.class.is_connec_more_recent?(connec_entities.first, external_entities.first, self)
    end

    if keep_external
      idmap.update(external_id: self.class.id_from_external_entity_hash(external_entities.first), name: self.class.object_name_from_external_entity_hash(external_entities.first))
      return {connec_entities: [], external_entities: [{entity: map_to_connec(external_entities.first), idmap: idmap}]}
    else
      entity = Maestrano::Connector::Rails::ConnecHelper.unfold_references(connec_entities.first, self.class.references, @organization)
      idmap.update(name: self.class.object_name_from_connec_entity_hash(entity))
      idmap.update(external_id: self.class.id_from_external_entity_hash(external_entities.first)) unless external_entities.empty?
      return {connec_entities: [{entity: map_to_external(entity), idmap: idmap}], external_entities: []}
    end
  end

  # ----------------------------------------------
  #             After and before sync
  # ----------------------------------------------
  def before_sync(last_synchronization)
    # Does nothing by default
  end

  def after_sync(last_synchronization)
    # Does nothing by default
  end
  # ----------------------------------------------
  #             Internal helper methods
  # ----------------------------------------------
  module ClassMethods
    def not_modified_since_last_push_to_connec?(idmap, entity, entity_instance, organization)
      not_modified = idmap.last_push_to_connec && idmap.last_push_to_connec > entity_instance.class.last_update_date_from_external_entity_hash(entity)
      Maestrano::Connector::Rails::ConnectorLogger.log('info', organization, "Discard #{Maestrano::Connector::Rails::External::external_name} #{entity_instance.class.external_entity_name} : #{entity}") if not_modified
      not_modified
    end

    def not_modified_since_last_push_to_external?(idmap, entity, entity_instance, organization)
      not_modified = idmap.last_push_to_external && idmap.last_push_to_external > entity['updated_at']
      Maestrano::Connector::Rails::ConnectorLogger.log('info', organization, "Discard Connec! #{entity_instance.class.connec_entity_name} : #{entity}") if not_modified
      not_modified
    end

    def is_connec_more_recent?(connec_entity, external_entity, entity_instance)
      connec_entity['updated_at'] > entity_instance.class.last_update_date_from_external_entity_hash(external_entity)
    end

    def solve_conflict(connec_entity, entity_instance, external_entities, external_entity_name, idmap, organization, opts)
      if external_entity = external_entities.find{|external_entity| connec_entity['id'] == external_entity['id']}
        # We keep the most recently updated entity
        if opts.has_key?(:connec_preemption)
          keep_connec = opts[:connec_preemption]
        else
          keep_connec = is_connec_more_recent?(connec_entity, external_entity, entity_instance)
        end

        if keep_connec
          Maestrano::Connector::Rails::ConnectorLogger.log('info', organization, "Conflict between #{Maestrano::Connector::Rails::External::external_name} #{external_entity_name} #{external_entity} and Connec! #{entity_instance.class.connec_entity_name} #{connec_entity}. Entity from external kept")
          external_entities.delete(external_entity)
          entity_instance.map_connec_entity_with_idmap(connec_entity, external_entity_name, idmap)
        else
          Maestrano::Connector::Rails::ConnectorLogger.log('info', organization, "Conflict between #{Maestrano::Connector::Rails::External::external_name} #{external_entity_name} #{external_entity} and Connec! #{entity_instance.class.connec_entity_name} #{connec_entity}. Entity from Connec! kept")
          nil
        end

      else
        entity_instance.map_connec_entity_with_idmap(connec_entity, external_entity_name, idmap)
      end
    end
  end
  

  def map_connec_entity_with_idmap(connec_entity, external_entity_name, idmap)
    {entity: map_to_external(connec_entity), idmap: idmap}
  end

  private
    def fetch_connec(uri, page_number)
      response = @connec_client.get(uri)
      raise "No data received from Connec! when trying to fetch page #{page_number} of #{self.class.normalized_connec_entity_name}" unless response && !response.body.blank?

      response_hash = JSON.parse(response.body)
      Maestrano::Connector::Rails::ConnectorLogger.log('debug', @organization, "received first page entity=#{self.class.connec_entity_name}, response=#{response_hash}")
      raise "Received unrecognized Connec! data when trying to fetch #{self.class.normalized_connec_entity_name}" unless response_hash["#{self.class.normalized_connec_entity_name}"]

      response_hash
    end

end