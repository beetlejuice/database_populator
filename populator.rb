require 'yaml'
require 'date'
require_relative 'ruby_extentions'

POPULATE_CONFIG_FILEPATH = './populate_config.yml'
NUMBER_CONFIG_FILEPATH = './populate_number.yml'
DYNAMIC_KPI_CONFIG_FILEPATH = './dynamic_kpi_config.yml'

INSERT_TEMPLATE = "insert into %s (%s) values (%s)" # 'insert into @table, ([@columns]) values (?,?,?)'
UPDATE_TEMPLATE = "update %s set ZISMODIFIED = 1 where Z_PK in (%s) and ZSTATUS != 'Closed'"

VISITS_MONTHS_INTERVAL = 6
DIFF_BETWEEN_UNIX_AND_IOS_TIME = 978307200
THIRTY_MINUTES_IN_MILLISECONDS = 1800000

MEDICAL_ORGANIZATION_RECORDTYPE_ID = '012D00000002XgpIAE'
MEDICAL_CONTACT_RECORDTYPE_ID = '012D00000002Xh4IAE'
PHARMACY_ORGANIZATION_RECORDTYPE_ID = '012D00000002XguIAE'
PHARMACY_CONTACT_RECORDTYPE_ID = '012D00000002aMvIAI'

VALUES_DIVIDER = '|'

class Populator

  attr_accessor :db, :populate_data

  def initialize(db)
    @db = db
  end

  def populate
    populate_data.each do |object|
      if object['number'].to_i > 0
        message_objects_str = prepare_log_message object

        case object['operation']
        when 'insert'
          p "Inserting #{message_objects_str}"
          insert_entities object
        when 'update'
          p "Updating #{message_objects_str}"
          update_entities object
        else
          p "No operation set for object kind: #{object[kind]}!"
        end
      end
    end
  end

  private

  def populate_data
    return @populate_data if @populate_data

    populate_config = YAML::load_file POPULATE_CONFIG_FILEPATH
    populate_number = YAML::load_file NUMBER_CONFIG_FILEPATH
    @populate_data = populate_config.deep_merge(populate_number)['data']
  end

  def prepare_log_message(object_data)
    message_objects = [object_data['kind']]

    related_objects = object_data['related_objects'] || []
    message_objects += related_objects.map{ |rel_obj| rel_obj['kind'] }

    message_objects.join(", ")
  end


  def insert_entities(object)
    rows_number = object['number'].to_i
    table = object['table']
    columns = object['columns_data'].keys
    data_kind = object['kind']
    data_template = object['columns_data'].values.join(VALUES_DIVIDER)
    parent_id = object['parent_id']
    related_objects = object['related_objects']

    entities_ids = get_new_ids_for_table(table, rows_number)
    entities_values = prepare_data_for_insert table, data_kind, data_template, entities_ids, parent_id

    db_query = bulk_insert_query(table, columns, entities_values)
    db.execute db_query

    increment_z_max(table, entities_ids.last)

    unless related_objects.nil?
      entities_ids.each do |id|
        related_objects.each do |related_object|
          related_object['parent_id'] = id
          insert_entities related_object
        end
      end
    end
  end

  def get_new_ids_for_table(table, quantity)
    last_id = get_table_last_id(table)
    quantity.times.map{ |i| last_id + i + 1 }
  end

  def get_table_last_id(table)
    db.execute "SELECT z_id FROM #{ table } LIMIT 1"
  end


  def update_entities(object)
    records_number = object['number'].to_i
    table = object['table']

    ids = get_random_record_ids(table, records_number)
    request = prepare_blank_update_request table, ids
    request.execute

    related_objects = object['related_objects']
    unless related_objects.nil?
      related_objects.each do |related_object|
        ids.each do |id|
          related_object['parent_id'] = id
          insert_entities related_object
        end
      end
    end
  end

  def get_random_record_ids(table, quantity)
    existing_records_count = get_records_count table
    quantity = (quantity <= existing_records_count) ? quantity : existing_records_count
    record_ids = db.execute("select z_pk from #{table} order by random() limit #{quantity}")
    record_ids.flatten
  end


  def bulk_insert_query(table, columns, entities_values)
    first_entity = entities_values.first

    values_as_columns = columns.map.with_index do |column, index|
      "'#{ first_entity[index] }' AS '#{ column }'"
    end.join(", ")

    unions  = entities_values.map do |values|
      "UNION ALL SELECT #{ values.split(VALUES_DIVIDER).join(", ") } "
    end.join

    query = "INSERT INTO %s SELECT %s %s"
    query % [table, values_as_columns, unions]
  end


  def prepare_blank_insert_request(table, columns)
    columns_string = columns.join(',')
    values_string = (['?']*columns.size).join(',') # (?, ?, ?)

    blank_request = INSERT_TEMPLATE % [table, columns_string, values_string]
    db.prepare blank_request
  end

  def prepare_blank_update_request(table, ids)
    blank_request = UPDATE_TEMPLATE % [table, ids.join(', ')]
    db.prepare blank_request
  end

  def prepare_data_for_insert(table, data_kind, data_template, entities_ids, parent_record_id = nil)
    case data_kind
    when 'medical_visits'
      prepare_data_for_medical_visits table, data_template, entities_ids
    when 'pharmacy_visits'
      prepare_data_for_pharmacy_visits table, data_template, entities_ids
    when 'medical_visit_data'
      prepare_data_for_medical_visit_data table, data_template, entities_ids, parent_record_id
    when 'pharmacy_visit_data'
      prepare_data_for_pharmacy_visit_data table, data_template, entities_ids, parent_record_id
    when 'visit_participants'
      prepare_data_for_visit_participants table, data_template, entities_ids, parent_record_id
    when 'dymanic_visit_data'
      prepare_data_for_dymanic_visit_data table, data_template, entities_ids, parent_record_id
    when 'pathologies'
      prepare_data_for_pathologies table, data_template, entities_ids, parent_record_id
    when 'pharma_evaluations'
      prepare_data_for_pharma_evaluations table, data_template, entities_ids, parent_record_id
    when 'contacts'
      prepare_data_for_contacts table, data_template, entities_ids
    when 'references'
      prepare_data_for_references table, data_template, entities_ids, parent_record_id
    when 'application_event_data'
      prepare_data_for_event_data table, data_template, entities_ids, parent_record_id
    when 'application_event_participants'
      prepare_data_for_event_participants table, data_template, entities_ids, parent_record_id
    when 'target_frequencies'
      prepare_data_for_target_frequencies table, data_template, entities_ids
    when 'organizations'
      prepare_data_for_organizations table, data_template, entities_ids
    when 'organization_additional_info'
      prepare_data_for_organization_additional_info table, data_template, entities_ids, parent_record_id
    when 'sales'
      prepare_data_for_sales table, data_template, entities_ids
    when 'medical_info_requests'
      prepare_data_for_medical_info_requests table, data_template, entities_ids
    else
      raise "No idea how to prepare data for: #{data_kind}"
    end
  end

  def prepare_data_for_medical_info_requests(table, template, entities_ids)
    data_array = []
    z_ent = get_z_ent(table)
    user_data = get_user

    entities_ids.each do |id|
      data_array << template % {
          :id => id,
          :z_ent => z_ent,
          :product => get_random_mir_product,
          :creation_date => generate_random_time,
          :user_name => user_data[:name],
          :user_id => user_data[:sf_id],
          :user_phone => user_data[:phone],
          :user_position => user_data[:position],
          :mir_description => "Generated #{time_now} description"
      }
    end
    data_array
  end

  def get_random_mir_product
    db.get_first_value("select z_pk from zmedicalinforequestproduct order by random() limit 1")
  end

  def prepare_data_for_sales(table, template, entities_ids)
    data_array = []
    z_ent = get_z_ent(table)
    year = Time.now.strftime("%Y")

    entities_ids.each do |id|
      data_array << template % {
          :id => id,
          :z_ent => z_ent,
          :month => rand(1..12),
          :year => year,
          :organization => get_random_pharmacy_organization[:id],
          :product_formulary => get_random_product_formulary
      }
    end
    data_array
  end

  def get_random_product_formulary
    db.get_first_value("select z_pk from zproductformulary where zproduct is not null order by random() limit 1")
  end

  def prepare_data_for_organization_additional_info(table, template, entities_ids, organization_id)
    data_array = []
    z_ent = get_z_ent(table)

    entities_ids.each do |id|
      data_array << template % {
          :id => id,
          :z_ent => z_ent,
          :organization => organization_id
      }
    end
    data_array
  end

  def prepare_data_for_organizations(table, template, entities_ids)
    data_array = []
    z_ent = get_z_ent(table)

    entities_ids.each_with_index do |id, i|
      brick_data = get_random_brick

      data_array << template % {
          :id => id,
          :z_ent => z_ent,
          :brick_city => brick_data[:city],
          :brick_id => brick_data[:sf_id],
          :name => "Generated #{time_now} organization-#{i}",
          :recordtype_id => PHARMACY_ORGANIZATION_RECORDTYPE_ID,
          :subtype => get_random_subtype_from_recordtype(PHARMACY_ORGANIZATION_RECORDTYPE_ID)
      }
    end
    data_array
  end

  def get_random_brick
    brick_data = db.execute("select zentityid, zparentid from zterritory where zsubtype = 'Brick' order by random() limit 1").first
    brick_sf_id = brick_data[0]
    brick_parent_id = brick_data[1]
    brick_city = db.get_first_value("select zcaption from zterritory where zentityid = '#{brick_parent_id}'")

    {:city => brick_city, :sf_id => brick_sf_id}
  end

  def get_random_subtype_from_recordtype(recordtype)
    db.get_first_value("select zvalue from zsubtype where zrecordtype = (select z_pk from zrecordtype where zentityid = '#{recordtype}' limit 1) order by random() limit 1")
  end

  def prepare_data_for_target_frequencies(table, template, entities_ids)
    data_array = []
    z_ent = get_z_ent(table)
    user_data = get_user
    target_id = get_target_id
    marketing_cycle_data = get_active_marketing_cycle

    entities_ids.each do |id|
      contact_data = get_random_medical_contact

      data_array << template % {
          :id => id,
          :z_ent => z_ent,
          :contact => contact_data[:id],
          :marketing_cycle => marketing_cycle_data[:id],
          :target_category => get_random_target_category_for_contact,
          :target_id => target_id,
          :user_id => user_data[:sf_id]
      }
    end
    data_array
  end

  def get_random_target_category_for_contact
    db.get_first_value("select zvalue from ztargetcategory where ZTYPE = 'ContactTargetCategory' order by random() limit 1")
  end

  def get_target_id
    target_data = db.execute("select zentityid from ztarget").first # TODO: check if this will work for RM
    target_data[0]
  end

  def prepare_data_for_event_data(table, template, entities_ids, event_id)
    data_array = []
    z_ent = get_z_ent(table)

    entities_ids.each do |id|
      product_data = get_random_product

      data_array << template % {
          :id => id,
          :z_ent => z_ent,
          :event => event_id,
          :product => product_data[:id]
      }
    end
    data_array
  end

  def prepare_data_for_event_participants(table, template, entities_ids, event_id)
    data_array = []
    z_ent = get_z_ent(table)

    entities_ids.each do |id|
      contact_data = get_random_contact

      data_array << template % {
          :id => id,
          :z_ent => z_ent,
          :contact => contact_data[:id],
          :event => event_id
      }
    end
    data_array
  end

  def prepare_data_for_contacts(table, template, entities_ids)
    data_array = []
    z_ent = get_z_ent(table)

    entities_ids.each_with_index do |id, i|
      data_array << template % {
          :id => id,
          :z_ent => z_ent,
          :first_name => "Contact-#{i}",
          :last_name => "Generated #{time_now}",
          :specialty => get_random_specialty,
          :recordtype_id => MEDICAL_CONTACT_RECORDTYPE_ID
      }
    end
    data_array
  end

  def time_now
    Time.now.strftime("%d-%m-%Y %R")
  end

  def get_random_specialty
    db.get_first_value("select ZVALUE from ZSUBTYPE where ZRECORDTYPE = (select Z_PK from ZRECORDTYPE where ZNAME = 'Контакт. Врач') order by random() limit 1")
  end

  def prepare_data_for_references(table, template, entities_ids, contact_id)
    data_array = []
    z_ent = get_z_ent(table)

    entities_ids.each do |id|
      medical_organization_data = get_random_medical_organization

      data_array << template % {
          :id => id,
          :z_ent => z_ent,
          :contact => contact_id,
          :organization => medical_organization_data[:id],
          :organization_id => medical_organization_data[:sf_id]
      }
    end
    data_array
  end

  def get_random_medical_organization
    organization_data = db.execute("select z_pk, zentityid from zorganization where zrecordtypeid = '#{MEDICAL_ORGANIZATION_RECORDTYPE_ID}' order by random() limit 1").first
    organization_id = organization_data[0]
    organization_sf_id = organization_data[1]

    {:id => organization_id, :sf_id => organization_sf_id}
  end

  def prepare_data_for_medical_visits(table, template, entities_ids)
    data_array = []
    z_ent = get_z_ent(table)
    marketing_cycle_data = get_active_marketing_cycle

    entities_ids.each do |id|
      start_date_time = generate_random_time
      end_date_time = start_date_time + THIRTY_MINUTES_IN_MILLISECONDS
      reference_data = get_random_reference

      data_array << template % {
          :id => id,
          :z_ent => z_ent,
          :medical_contact => reference_data[:contact_id],
          :medical_organization => reference_data[:organization_id],
          :medical_contact_id => reference_data[:contact_sf_id],
          :medical_organization_id => reference_data[:organization_sf_id],
          :date_start => start_date_time,
          :date_end => end_date_time,
          :marketing_cycle_id => marketing_cycle_data[:sf_id],
          :status => generate_random_status,
          :user_id => get_user[:sf_id]
      }
    end
    data_array
  end

  def prepare_data_for_pharmacy_visits(table, template, entities_ids)
    data_array = []
    z_ent = get_z_ent(table)
    marketing_cycle_data = get_active_marketing_cycle

    entities_ids.each do |id|
      start_date_time = generate_random_time
      end_date_time = start_date_time + THIRTY_MINUTES_IN_MILLISECONDS
      pharmacy_organization_data = get_random_pharmacy_organization

      data_array << template % {
          :id => id,
          :z_ent => z_ent,
          :pharmacy_organization => pharmacy_organization_data[:id],
          :pharmacy_organization_id => pharmacy_organization_data[:sf_id],
          :date_start => start_date_time,
          :date_end => end_date_time,
          :marketing_cycle_id => marketing_cycle_data[:sf_id],
          :status => generate_random_status,
          :user_id => get_user[:sf_id]
      }
    end
    data_array
  end

  def get_active_marketing_cycle
    marketing_cycle_data = db.execute("select z_pk, zentityid from zmarketingcycle where zisactive = 1").first
    marketing_cycle_id = marketing_cycle_data[0]
    marketing_cycle_sf_id = marketing_cycle_data[1]

    {:id => marketing_cycle_id, :sf_id => marketing_cycle_sf_id}
  end

  def prepare_data_for_medical_visit_data(table, template, entities_ids, visit_id)
    data_array = []
    # z_ent = get_z_ent(table)
    z_ent = get_z_ent('ZVISITPRODUCTDATA') # TODO: dirty hack

    entities_ids.each_with_index do |id, i|
      data_array << template % {
          :id => id,
          :z_ent => z_ent,
          :product => get_random_product[:id],
          :visit => visit_id,
          :detail_sequence => i
      }
    end
    data_array
  end


  def prepare_data_for_pharmacy_visit_data(table, template, entities_ids, visit_id)
    data_array = []
    # z_ent = get_z_ent(table)
    z_ent = get_z_ent('ZVISITPRODUCTDATA') # TODO: dirty hack

    entities_ids.each_with_index do |id, i|
      data_array << template % {
          :id => id,
          :z_ent => z_ent,
          :product => get_random_product[:id],
          :visit => visit_id
      }
    end
    data_array
  end

  def prepare_data_for_visit_participants(table, template, entities_ids, visit_id)
    data_array = []
    z_ent = get_z_ent(table)

    entities_ids.each do |id|
      pharmacy_contact_data = get_random_pharmacy_contact

      data_array << template % {
        :id => id,
        :z_ent => z_ent,
        :contact => pharmacy_contact_data[:id],
        :contact_id => pharmacy_contact_data[:sf_id],
        :visit => visit_id
      }
    end
    data_array
  end


  def prepare_data_for_pharma_evaluations(table, template, entities_ids, visit_id)
    data_array = []
    z_ent = get_z_ent(table)
    user_data = get_user
    visit_info = get_visit_info visit_id

    entities_ids.each do |id|
      product_data = get_random_product

      data_array << template % {
          :id => id,
          :z_ent => z_ent,
          :contact => visit_info[:contact_id],
          :contact_id => visit_info[:contact_sf_id],
          :product => product_data[:id],
          :product_id => product_data[:sf_id],
          :visit => visit_id,
          :visit_date => visit_info[:date],
          :user_division => user_data[:division],
          :user_id => user_data[:sf_id],
          :user_name => user_data[:name]
      }
    end
    data_array
  end

  def get_visit_info(visit_id)
    visit_info = @db.execute("select ZDATETIME, ZCONTACT, ZCONTACTID from ZVISIT where Z_PK = #{visit_id}").first
    visit_date = visit_info[0]
    contact_id = visit_info[1]
    contact_sf_id = visit_info[2]

    {:date => visit_date, :contact_id => contact_id, :contact_sf_id => contact_sf_id}
  end

  def prepare_data_for_pathologies(table, template, entities_ids, visit_id)
    data_array = []
    z_ent = get_z_ent(table)
    user_data = get_user
    visit_info = get_visit_info visit_id

    entities_ids.each do |id|
      product_data = get_random_product

      data_array << template % {
          :id => id,
          :z_ent => z_ent,
          :contact => visit_info[:contact_id],
          :product => product_data[:id],
          :visit => visit_id,
          :name => "Тестовая патология-#{i}",
          :user_division => user_data[:division],
          :user_id => user_data[:sf_id]
      }
    end

    data_array
  end

  def prepare_data_for_dymanic_visit_data(table, template, entities_ids, visit_id)
    data_array = []
    z_ent = get_z_ent(table)
    dynamic_visit_data = get_dynamic_visit_data_config

    entities_ids.each do |id|
      data_array << template % {
          :id => id,
          :z_ent => z_ent,
          :product => dynamic_visit_data[:product],
          :visit => visit_id,
          :json => dynamic_visit_data[:json]
      }
    end
    data_array
  end

  def get_dynamic_visit_data_config
    config = YAML::load_file DYNAMIC_KPI_CONFIG_FILEPATH
    dynamic_kpi_product = config['dynamic_kpi_product']
    dynamic_kpi_json = config['dynamic_kpi_json'] % {
      :slide_id => config['dynamic_kpi_slide'],
      :product => dynamic_kpi_product
    }

    {:product => dynamic_kpi_product, :json => dynamic_kpi_json}
  end

  def get_z_ent(zobject)
    object_name = zobject[1..-1] # ZVISIT => VISIT
    db.get_first_value("select z_ent from z_primarykey where upper(z_name) = '#{object_name}'")
  end

  def generate_random_status
    %w(Processing Completed).sample
  end

  def generate_random_time
    today = Date.today
    from = (today << (VISITS_MONTHS_INTERVAL - 1)).to_time
    to = today.to_time
    rand_time = Time.at(from + rand * (to.to_f - from.to_f))
    convert_to_ios_time rand_time
  end

  def convert_to_ios_time(time)
    time.to_i - DIFF_BETWEEN_UNIX_AND_IOS_TIME
  end

  def get_random_reference
    reference_ids = db.execute("select zcontact, zorganization from zreference where zcontact in (select z_pk from zcontact where zrecordtypeid = '#{MEDICAL_CONTACT_RECORDTYPE_ID}') order by random() limit 1").first
    contact_id = reference_ids[0]
    organization_id = reference_ids[1]
    contact_sf_id = db.get_first_value("select zentityid from zcontact where z_pk = #{contact_id}")
    organization_sf_id = db.get_first_value("select zentityid from zorganization where z_pk = #{organization_id}")

    {:contact_id => contact_id, :organization_id => organization_id,
     :contact_sf_id => contact_sf_id, :organization_sf_id => organization_sf_id}
  end

  def get_random_pharmacy_organization
    organization_data = db.execute("select z_pk, zentityid from zorganization where zsubtype = 'Аптека' order by random() limit 1").first
    organization_id = organization_data[0]
    organization_sf_id = organization_data[1]

    {:id => organization_id, :sf_id => organization_sf_id}
  end

  def get_user
    user_data = db.execute("select zentityid, zname, zuserdivision, zmobilephone, zposition from zuser").first r
    user_sf_id = user_data[0]
    user_name = user_data[1]
    user_division = user_data[2]
    user_phone = user_data[3]
    user_position = user_data[4]

    {:sf_id => user_sf_id, :name => user_name, :division => user_division, :phone => user_phone, :position => user_position}
  end

  def get_random_product
    product_data = db.execute("select z_pk, zentityid from zproduct order by random() limit 1").first
    product_id = product_data[0]
    product_sf_id = product_data[1]

    {:id => product_id, :sf_id => product_sf_id}
  end

  def get_random_contact(type = nil)
    recordtype = case type
                 when :medical then MEDICAL_CONTACT_RECORDTYPE_ID
                 when :pharmacy then PHARMACY_CONTACT_RECORDTYPE_ID
                 else [MEDICAL_CONTACT_RECORDTYPE_ID, PHARMACY_CONTACT_RECORDTYPE_ID].sample
                 end

    contact_data = db.execute("select z_pk, zentityid from zcontact where zrecordtypeid = '#{recordtype}' order by random() limit 1").first
    contact_id = contact_data[0]
    contact_sf_id = contact_data[1]

    {:id => contact_id, :sf_id => contact_sf_id}
  end

  def get_random_medical_contact
    get_random_contact :medical
  end

  def get_random_pharmacy_contact
    get_random_contact :pharmacy
  end

  def get_records_count(table)
    db.get_first_value("select count() from #{table}").to_i
  end

  def increment_z_max(table_name, z_max)
    z_name = table_name[1..-1]
    db.execute("update z_primarykey set z_max = #{z_max} where upper(z_name) = '#{z_name}'")
  end
end