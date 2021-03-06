class ChargebackRate < ActiveRecord::Base
  include UuidMixin
  include ReportableMixin

  ASSIGNMENT_PARENT_ASSOCIATIONS = [:host, :ems_cluster, :storage, :ext_management_system, :my_enterprise]
  include AssignmentMixin

  has_many :chargeback_rate_details, :dependent => :destroy

  validates_presence_of     :description, :guid
  validates_uniqueness_of   :guid
  validates_uniqueness_of   :description, :scope => :rate_type

  FIXTURE_DIR = File.join(Rails.root, "db/fixtures")

  VALID_CB_RATE_TYPES = ["Compute", "Storage"]

  def self.validate_rate_type(type)
    unless VALID_CB_RATE_TYPES.include?(type.to_s.capitalize)
      raise "Chargeback rate type '#{type}' is not supported"
    end
  end

  def self.get_assignments(type)
    # type = :compute || :storage
    # Returns[{:cb_rate=>obj, :tag=>[Classification.entry_object, klass]} || :object=>object},...]
    validate_rate_type(type)
    result = []
    ChargebackRate.where(:rate_type => type.to_s.capitalize).each do |rate|
      assigned_tos = rate.get_assigned_tos
      assigned_tos[:tags].each    { |tag|    result << {:cb_rate => rate, :tag => tag} }
      assigned_tos[:objects].each { |object| result << {:cb_rate => rate, :object => object} }
    end
    result
  end

  def self.set_assignments(type, cb_rates)
    validate_rate_type(type)
    ChargebackRate.where(:rate_type => type.to_s.capitalize).each(&:remove_all_assigned_tos)

    cb_rates.each do |rate|
      rate[:cb_rate].assign_to_objects(rate[:object]) if rate.key?(:object)
      rate[:cb_rate].assign_to_tags(*rate[:tag])      if rate.key?(:tag)
    end
  end

  def self.seed
    # seeding the measure fixture before seed the chargeback rates fixtures
    seed_chargeback_rate_measure
    seed_chargeback_rate
  end

  def self.seed_chargeback_rate_measure
    fixture_file_measure = File.join(FIXTURE_DIR, "chargeback_rates_measures.yml")
    if File.exist?(fixture_file_measure)
      fixture = YAML.load_file(fixture_file_measure)
      fixture.each do |cbr|
        rec = ChargebackRateDetailMeasure.find_by_name(cbr[:name])
        if rec.nil?
          _log.info("Creating [#{cbr[:name]}] with units=[#{cbr[:units]}]")
          rec = ChargebackRateDetailMeasure.create(cbr)
        else
          fixture_mtime = File.mtime(fixture_file_measure).utc
          if fixture_mtime > rec.created_at
            _log.info("Updating [#{cbr[:name]}] with units=[#{cbr[:units]}]")
            rec.update_attributes(cbr)
            rec.created_at = fixture_mtime
            rec.save
          end
        end
      end
    end
  end

  def self.seed_chargeback_rate
    # seeding the rates fixtures
    fixture_file = File.join(FIXTURE_DIR, "chargeback_rates.yml")
    fixture_file_measure = File.join(FIXTURE_DIR, "chargeback_rates_measures.yml")

    if File.exist?(fixture_file)
      fixture = YAML.load_file(fixture_file)
      fixture.each do |cbr|
        rec = find_by_guid(cbr[:guid])
        rates = cbr.delete(:rates)
        # The yml measure field is the name of the measure. It's changed to the id
        rates.each do |rate_detail|
          measure = ChargebackRateDetailMeasure.find_by(:name => rate_detail.delete(:measure))
          unless measure.nil?
            rate_detail[:chargeback_rate_detail_measure_id] = measure.id
          end
        end
        if rec.nil?
          _log.info("Creating [#{cbr[:description]}] with guid=[#{cbr[:guid]}]")
          rec = create(cbr)
          rec.chargeback_rate_details.create(rates)
        else
          fixture_mtime = File.mtime(fixture_file).utc
          fixture_mtime_measure = File.mtime(fixture_file_measure).utc
          if fixture_mtime > rec.created_on || fixture_mtime_measure > rec.created_on
            _log.info("Updating [#{cbr[:description]}] with guid=[#{cbr[:guid]}]")
            rec.update_attributes(cbr)
            rec.chargeback_rate_details.clear
            rec.chargeback_rate_details.create(rates)
            rec.created_on = fixture_mtime
            rec.save
          end
        end
      end
    end
  end
end
