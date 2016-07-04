require 'sqlite3'
require 'yaml'
require 'date'

POPULATE_CONFIG_FILEPATH = './populate_config.yml'
NUMBER_CONFIG_FILEPATH = './populate_number.yml'
DYNAMIC_KPI_CONFIG_FILEPATH = './dynamic_kpi_config.yml'

INSERT_TEMPLATE = "insert into %s (%s) values (%s)" # 'insert into @table, ([@columns]) values (?,?,?)'
UPDATE_TEMPLATE = "update %s set ZISMODIFIED = 1 where Z_PK in (%s)"

VISITS_MONTHS_INTERVAL = 6
DIFF_BETWEEN_UNIX_AND_IOS_TIME = 978307200
THIRTY_MINUTES_IN_MILLISECONDS = 1800000

MEDICAL_ORGANIZATION_RECORDTYPE_ID = '012D00000002XgpIAE'
MEDICAL_CONTACT_RECORDTYPE_ID = '012D00000002Xh4IAE'
PHARMACY_CONTACT_RECORDTYPE_ID = '012D00000002aMvIAI'

class Populator

  attr_accessor :db, :populate_data

  def initialize(db)
    @db = db
  end

  def populate
    populate_data.each do |object|
      if object['number'].to_i > 0
        case object['operation']
          when 'insert'
            insert_object object
          when 'update'
            update_object object
          else
            p "No operation set for object kind: #{object[kind]}!"
        end
      end
    end
  end

  def populate_data
    if @populate_data.nil?
      populate_config = YAML::load_file POPULATE_CONFIG_FILEPATH
      populate_number = YAML::load_file NUMBER_CONFIG_FILEPATH

      # populate_config.merge(populate_number){ |key, v1, v2| v1.zip(v2).map{ |h1, h2| h1.merge(h2) } }['data']
      merge_configs(populate_config, populate_number) # hash['data']
    else
      @populate_data
    end
  end

  private

  def merge_configs *configs
    # TODO: implement
    # result_hash['data']
  end

  def insert_object(object, parent_id = nil)
    records_number = object['number'].to_i
    table = object['table']
    columns = object['columns_data'].keys
    data_kind = object['kind']
    data_template = object['columns_data'].values

    request = prepare_blank_insert_request table, columns
    records_data = prepare_data_for_insert table, data_kind, data_template, records_number, parent_id

    records_data.each do |record_data|
      request.execute *record_data

      related_objects = object['related_objects']
      unless related_objects.nil?
        parent_id = @db.last_insert_row_id
        related_objects.each do |related_object|
          insert_object related_object, parent_id
        end
      end
    end
  end

  def update_object(object)
    records_number = object['number'].to_i
    table = object['table']

    ids = get_random_record_ids(table, records_number).join(', ')
    request = prepare_blank_update_request table, ids
    request.execute

    related_objects = object['related_objects']
    unless related_objects.nil?
      related_objects.each do |related_object|
        ids.each do |id|
          insert_object related_object, id
        end
      end
    end
  end

  def get_random_record_ids(table, quantity)
    @db.execute "select Z_PK from #{table} order by random() limit #{quantity}"
  end

  def prepare_blank_insert_request(table, columns)
    columns_string = columns.join(',')
    values_string = (['?']*columns.size).join(',') # (?, ?, ?)

    blank_request = INSERT_TEMPLATE % [table, columns_string, values_string]
    @db.prepare blank_request
  end

  def prepare_blank_update_request(table, ids)
    blank_request = UPDATE_TEMPLATE % [table, ids]
    @db.prepare blank_request
  end

  def prepare_data_for_insert(table, data_kind, data_template, records_number, parent_record_id = nil)
    case data_kind
    when 'medical_visits'
      prepare_data_for_medical_visits table, data_template, records_number
    when 'pharmacy_visits'
      prepare_data_for_pharmacy_visits table, data_template, records_number
    when 'medical_visit_data'
      prepare_data_for_medical_visit_data table, data_template, records_number, parent_record_id
    when 'pharmacy_visit_data'
      prepare_data_for_pharmacy_visit_data table, data_template, records_number, parent_record_id
    when 'visit_participants'
      prepare_data_for_visit_participants table, data_template, records_number, parent_record_id
    when 'dymanic_visit_data'
      prepare_data_for_dymanic_visit_data table, data_template, records_number, parent_record_id
    when 'pathologies'
      prepare_data_for_pathologies table, data_template, records_number, parent_record_id
    when 'pharma_evaluations'
      prepare_data_for_pharma_evaluations table, data_template, records_number, parent_record_id
    when 'contact'
      prepare_data_for_contacts table, data_template, records_number
    when 'references'
      prepare_data_for_references table, data_template, records_number, parent_record_id
    when 'application_event_data'
      prepare_data_for_event_data table, data_template, records_number, parent_record_id
    when 'application_event_participants'
      prepare_data_for_event_participants table, data_template, records_number, parent_record_id
    when 'target_frequencies'
      prepare_data_for_target_frequencies table, data_template, records_number
    else
      raise "No idea how to prepare data for: #{data_kind}"
    end
  end

  def prepare_data_for_target_frequencies(table, data_template, records_number)
    data_array = []
    user_data = get_user
    contact_data = get_random_medical_contact
    marketing_cycle_data = get_active_marketing_cycle

    records_number.times do
      data_array << template % {
          :z_ent => get_z_ent(table),
          :contact => contact_data[:id],
          :marketing_cycle => marketing_cycle_data[id],
          :target_category => get_random_target_category_for_contact,
          :target_id => get_target_id,
          :user_id => user_data[:sf_id]
      }
    end
    data_array
  end

  def get_random_target_category_for_contact
    @db.execute("select zvalue from ztargetcategory where ZTYPE = 'ContactTargetCategory' order by random() limit 1").first
  end

  def get_target_id
    target_data = @db.execute("select zentityid from ztarget").first # TODO: check if this will work for RM
    target_data[0]
  end

  def prepare_data_for_event_data(table, data_template, records_number, parent_record_id)
    data_array = []
    product_data = get_random_product

    records_number.times do
      data_array << template % {
          :z_ent => get_z_ent(table),
          :event => parent_record_id,
          :product => product_data[:id]
      }
    end
    data_array
  end

  def prepare_data_for_event_participants(table, template, records_number, parent_record_id)
    data_array = []
    contact_data = get_random_contact

    records_number.times do
      data_array << template % {
          :z_ent => get_z_ent(table),
          :contact => contact_data[:id],
          :event => parent_record_id
      }
    end
    data_array
  end

  def prepare_data_for_contacts(table, template, records_number)
    data_array = []
    time_now = Time.now.strftime("%d-%m-%Y %R")

    records_number.times do |i|
      data_array << template % {
          :z_ent => get_z_ent(table),
          :first_name => "Contact-#{i}",
          :last_name => "Generated #{time_now}",
          :specialty => get_random_specialty
      }
    end
    data_array
  end

  def get_random_specialty
    @db.execute("select ZVALUE from ZSUBTYPE where ZRECORDTYPE = (select Z_PK from ZRECORDTYPE where ZNAME = 'Контакт. Врач') order by random() limit 1").first
  end

  def prepare_data_for_references(table, template, records_number, contact_id)
    data_array = []
    medical_organization_data = get_random_medical_organization

    records_number.times do
      data_array << template % {
          :z_ent => get_z_ent(table),
          :contact => contact_id,
          :organization => medical_organization_data[:id],
          :id => medical_organization_data[:sf_id]
      }
    end
    data_array
  end

  def get_random_medical_organization
    organization_data = @db.execute("select z_pk, zentityid from zorganization where zrecordtypeid = #{MEDICAL_ORGANIZATION_RECORDTYPE_ID} order by random() limit 1").first
    organization_id = organization_data[0]
    organization_sf_id = organization_data[1]

    {:id => organization_id, :sf_id => organization_sf_id}
  end

  def prepare_data_for_medical_visits(table, template, records_number)
    data_array = []
    start_date_time = generate_random_time
    end_date_time = start_date_time + THIRTY_MINUTES_IN_MILLISECONDS
    marketing_cycle_data = get_active_marketing_cycle
    reference_data = get_random_reference

    records_number.times do
      data_array << template % {
          :z_ent => get_z_ent(table),
          :medical_contact => reference_data[:contact_id],
          :medical_organization => reference_data[:organization_id],
          :medical_contact_id => reference_data[:contact_sf_id],
          :medical_organization_id => reference_data[:organization_sf_id],
          :date_start => start_date_time,
          :date_end => end_date_time,
          :marketing_cycle => marketing_cycle_data[:sf_id],
          :status => generate_random_status,
          :user_id => get_user[:sf_id]
      }
    end
    data_array
  end

  def prepare_data_for_pharmacy_visits(table, template, records_number)
    data_array = []
    start_date_time = generate_random_time
    end_date_time = start_date_time + THIRTY_MINUTES_IN_MILLISECONDS
    marketing_cycle_data = get_active_marketing_cycle
    pharmacy_organization_data = get_random_pharmacy_organization

    records_number.times do
      data_array << template % {
          :z_ent => get_z_ent(table),
          :pharmacy_organization => pharmacy_organization_data[:id],
          :pharmacy_organization_id => pharmacy_organization_data[:sf_id],
          :date_start => start_date_time,
          :date_end => end_date_time,
          :marketing_cycle => marketing_cycle_data[:sf_id],
          :status => generate_random_status,
          :user_id => get_user[:sf_id]
      }
    end
    data_array
  end

  def get_active_marketing_cycle
    marketing_cycle_data = @db.execute("select z_pk, zentityid from zmarketingcycle where zisactive = 1").first
    id = marketing_cycle_data[0]
    sf_id = marketing_cycle_data[1]

    {:id => id, :sf_id => sf_id}
  end

  def prepare_data_for_medical_visit_data(table, template, records_number, parent_record_id)
    data_array = []

    records_number.times do |i|
      data_array << template % {
          :z_ent => get_z_ent(table),
          :product => get_random_product[:id],
          :visit => parent_record_id,
          :detail_sequence => i
      }
    end
    data_array
  end

  def prepare_data_for_pharmacy_visit_data(table, template, records_number, parent_record_id)
    data_array = []

    records_number.times do |i|
      data_array << template % {
          :z_ent => get_z_ent(table),
          :product => get_random_product[:id],
          :visit => parent_record_id
      }
    end
    data_array
  end

  def prepare_data_for_visit_participants(table, template, records_number, parent_record_id)
    data_array = []
    pharmacy_contact_data = get_random_pharmacy_contact

    records_number.times do
      data_array << template % {
          :z_ent => get_z_ent(table),
          :contact => pharmacy_contact_data[:id],
          :contact_id => pharmacy_contact_data[:sf_id],
          :visit => parent_record_id
      }
    end
    data_array
  end

  def prepare_data_for_pharma_evaluations(table, template, records_number, parent_record_id)
    data_array = []
    user_data = get_user
    visit_data = get_visit_data parent_record_id
    product_data = get_random_product

    records_number.times do
      data_array << template % {
          :z_ent => get_z_ent(table),
          :contact => visit_data[:contact_id],
          :contact_id => visit_data[:contact_sf_id],
          :product => product_data[:id],
          :product_id => product_data[:sf_id],
          :visit => parent_record_id,
          :visit_date => visit_data[:date],
          :user_division => user_data[:division],
          :user_id => user_data[:sf_id],
          :user_name => user_data[:name]
      }
    end
    data_array
  end

  def get_visit_data(parent_record_id)
    visit_data = @db.execute("select ZDATETIME, ZCONTACT, ZCONTACTID from ZVISIT where Z_PK = #{parent_record_id}").first
    visit_date = visit_data[0]
    contact_id = visit_data[1]
    contact_sf_id = visit_data[2]

    {:date => visit_date, :contact_id => contact_id, :contact_sf_id => contact_sf_id}
  end

  def prepare_data_for_pathologies(table, template, records_number, parent_record_id)
    data_array = []
    user_data = get_user
    visit_data = get_visit_data parent_record_id
    product_data = get_random_product

    records_number.times do
      data_array << template % {
          :z_ent => get_z_ent(table),
          :contact => visit_data[:contact_id],
          :product => product_data[:id],
          :visit => parent_record_id,
          :user_division => user_data[:division],
          :user_id => user_data[:sf_id]
      }
    end
    data_array
  end

  def prepare_data_for_dymanic_visit_data(table, template, records_number, parent_record_id)
    data_array = []
    dynamic_visit_data = get_dynamic_visit_data_config

    records_number.times do
      data_array << template % {
          :z_ent => get_z_ent(table),
          :product => dynamic_visit_data[:product],
          :visit => parent_record_id,
          :json => dynamic_visit_data[:json]
      }
    end
    data_array
  end

  def get_dynamic_visit_data_config
    config = YAML::load DYNAMIC_KPI_CONFIG_FILEPATH
    product = config['dynamic_kpi_product']
    json = config['dynamic_kpi_json'] % {
      :slide_id => config['dynamic_kpi_slide'],
      :product => product
    }

    {:product => product, :json => json}
  end

  def get_z_ent(zobject)
    object_name = zobject[1..-1]
    $db.execute("select z_ent from z_primarykey where upper(z_name) = '#{object_name}'").first
  end

  def generate_random_status
    %w(Open Processing Closed).pick
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
    reference_ids = @db.execute("select zcontact, zorganization from zreference where zcontact in (select z_pk from zcontact where zspecialty = 'Терапевт') order by random() limit 1").first
    contact_id = reference_ids[0]
    organization_id = reference_ids[1]
    contact_sf_id = @db.execute("select zentityid from zcontact where z_pk = #{contact}")
    organization_sf_id = @db.execute("select zentityid from zorganization where z_pk = #{organization}")

    {:contact_id => contact_id, :organization_id => organization_id,
     :contact_sf_id => contact_sf_id, :organization_sf_id => organization_sf_id}
  end

  def get_random_pharmacy_organization
    organization_data = @db.execute("select z_pk, zentityid from zorganization where zsubtype = 'Аптека' order by random() limit 1").first
    organization_id = organization_data[0]
    organization_sf_id = organization_data[1]

    {:id => organization_id, :sf_id => organization_sf_id}
  end

  def get_user
    user_data = @db.execute("select zentityid, zname, zuserdivision from zuser").first
    user_sf_id = user_data[0]
    user_name = user_data[1]
    user_division = user_data[2]

    {:sf_id => user_sf_id, :name => user_name, :division => user_division}
  end

  def get_random_product
    product_data = @db.execute("select z_pk, zentityid from zproduct order by random() limit 1").first
    product_id = product_data[0]
    product_sf_id = product_data[1]

    {:id => product_id, :sf_id => product_sf_id}
  end

  def get_random_contact(type = nil) # TODO: implement
    recordtype = case type
                 when :medical then MEDICAL_CONTACT_RECORDTYPE_ID
                 when :pharmacy then PHARMACY_CONTACT_RECORDTYPE_ID
                 else %w(MEDICAL_CONTACT_RECORDTYPE_ID PHARMACY_CONTACT_RECORDTYPE_ID).pick
                 end

    contact_data = @db.execute("select z_pk, zentityid from zcontact where zrecordtypeid = '#{recordtype}' order by random() limit 1").first
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

end

# def fix_coredata # call after all modifications
#   # set z_max for all objects
# end