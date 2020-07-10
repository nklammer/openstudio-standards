require_relative '../helpers/minitest_helper'
require_relative '../helpers/create_doe_prototype_helper'

# Test suite for the ASHRAE 90.1 appendix G Performance
# Rating Method (PRM) baseline automation implementation
# in openstudio-standards.
# @author Doug Maddox (PNNL), Jeremy Lerond (PNNL), and Yunyang Ye (PNNL)
class AppendixGPRMTests < Minitest::Test
  # Set folder for JSON files related to tests and
  # parse individual JSON files used by all methods
  # in this class.
  @@json_dir = "#{File.dirname(__FILE__)}/data"
  @@prototype_list = JSON.parse(File.read("#{@@json_dir}/prototype_list.json"))
  @@wwr_building_types = JSON.parse(File.read("#{@@json_dir}/wwr_building_types.json"))
  @@hvac_building_types = JSON.parse(File.read("#{@@json_dir}/hvac_building_types.json"))
  @@swh_building_types = JSON.parse(File.read("#{@@json_dir}/swh_building_types.json"))
  @@wwr_values = JSON.parse(File.read("#{@@json_dir}/wwr_values.json"))
  @@hasres_values = JSON.parse(File.read("#{@@json_dir}/hasres_values.json"))

  # Generate one of the ASHRAE 90.1 prototype model included in openstudio-standards.
  #
  # @param prototypes_to_generate [Array] List of prototypes to generate, see prototype_list.json to see the structure of the list
  #
  # @return [Hash] Hash of OpenStudio Model of the prototypes
  def generate_prototypes(prototypes_to_generate)
    prototypes = {}
    prototypes_to_generate.each do |id, prototype|
      # mod is an array of method intended to modify the model
      building_type, template, climate_zone, mod = prototype

      # Initialize weather file, necessary but not used
      epw_file = 'USA_FL_Miami.Intl.AP.722020_TMY3.epw'

      # Create output folder if it doesn't already exist
      @test_dir = "#{File.dirname(__FILE__)}/output"
      if !Dir.exist?(@test_dir)
        Dir.mkdir(@test_dir)
      end

      # Define model name and run folder if it doesn't already exist,
      # if it does, remove it and re-create it.
      model_name = "#{building_type}-#{template}-#{climate_zone}"
      run_dir = "#{@test_dir}/#{model_name}"
      if !Dir.exist?(run_dir)
        Dir.mkdir(run_dir)
      else
        FileUtils.rm_rf(run_dir)
        Dir.mkdir(run_dir)
      end

      # Create the prototype
      prototype_creator = Standard.build("#{template}_#{building_type}")
      model = prototype_creator.model_create_prototype_model(climate_zone, epw_file, run_dir)

      # Make modification if requested
      # TODO: To be tested, all method_mod should return the model
      if !mod.empty?
        mod.each do |method_mod|
          model = public_send(method_mod, model)
        end
      end

      # Save prototype OSM file
      osm_path = OpenStudio::Path.new("#{run_dir}/#{model_name}.osm")
      model.save(osm_path, true)

      # Translate prototype model to an IDF file
      forward_translator = OpenStudio::EnergyPlus::ForwardTranslator.new
      idf_path = OpenStudio::Path.new("#{run_dir}/#{model_name}.idf")
      idf = forward_translator.translateModel(model)
      idf.save(idf_path, true)

      # Save OpenStudio model object
      prototypes[id] = model
    end
    return prototypes
  end

  # Generate the 90.1 Appendix G baseline for a model following the 90.1-2019 PRM rules
  #
  # @param prototypes_generated [Array] List of all unique prototypes for which baseline models will be created
  # @param id_prototype_mapping [Hash] Mapping of prototypes to their identifiers generated by prototypes_to_generate()
  #
  # @return [Hash] Hash of OpenStudio Model of the prototypes
  def generate_baseline(prototypes_generated, id_prototype_mapping)
    baseline_prototypes = {}
    prototypes_generated.each do |id, model|
      building_type, template, climate_zone, mod = id_prototype_mapping[id]

      # Initialize Standard class
      prototype_creator = Standard.build('90.1-PRM-2019')

      # Convert standardSpaceType string for each space to values expected for prm creation
      lpd_space_types = JSON.parse(File.read("#{@@json_dir}/lpd_space_types.json"))
      model.getSpaceTypes.sort.each do |space_type|
        next if space_type.floorArea == 0

        standards_space_type = if space_type.standardsSpaceType.is_initialized
                                 space_type.standardsSpaceType.get
                               end
        std_bldg_type = space_type.standardsBuildingType.get
        bldg_type_space_type = std_bldg_type + space_type.standardsSpaceType.get
        new_space_type = lpd_space_types[bldg_type_space_type]
        space_type.setStandardsSpaceType(lpd_space_types[bldg_type_space_type])
      end

      # Define run directory and run name, delete existing folder if it exists
      model_name = "#{building_type}-#{template}-#{climate_zone}"
      run_dir = "#{@test_dir}/#{model_name}"
      run_dir_baseline = "#{run_dir}-Baseline"
      if Dir.exist?(run_dir_baseline)
        FileUtils.rm_rf(run_dir_baseline)
      end

      # Create baseline model
      model_baseline = prototype_creator.model_create_prm_stable_baseline_building(model, building_type, climate_zone,
                                                                                   @@hvac_building_types[building_type],
                                                                                   @@wwr_building_types[building_type],
                                                                                   @@swh_building_types[building_type],
                                                                                   nil, run_dir_baseline, false)

      # Check if baseline could be created
      assert(model_baseline, "Baseline model could not be generated for #{building_type}, #{template}, #{climate_zone}.")

      # Load newly generated baseline model
      @test_dir = "#{File.dirname(__FILE__)}/output"
      model_baseline = OpenStudio::Model::Model.load("#{@test_dir}/#{building_type}-#{template}-#{climate_zone}-Baseline/final.osm")
      model_baseline = model_baseline.get

      # Do sizing run for baseline model
      sim_control = model_baseline.getSimulationControl
      sim_control.setRunSimulationforSizingPeriods(true)
      sim_control.setRunSimulationforWeatherFileRunPeriods(false)
      baseline_run = prototype_creator.model_run_simulation_and_log_errors(model_baseline, "#{@test_dir}/#{building_type}-#{template}-#{climate_zone}-Baseline/SR1")

      # Add prototype to the list of baseline prototypes generated
      baseline_prototypes[id] = model_baseline
    end
    return baseline_prototypes
  end

  # Write out a SQL query to retrieve simulation outputs
  # from the TabularDataWithStrings table in the SQL
  # database produced by OpenStudio/EnergyPlus after
  # running a simulation.
  #
  # @param model [OpenStudio::Model::Model] OpenStudio model object
  # @param report_name [String] Name of the report as defined in the HTM simulation output file
  # @param table_name [String] Name of the table as defined in the HTM simulation output file
  # @param row_name [String] Name of the row as defined in the HTM simulation output file
  # @param column_name [String] Name of the column as defined in the HTM simulation output file
  # @param units [String] Unit of the value to be retrieved
  #
  # @return [String] Result of the query
  def run_query_tabulardatawithstrings(model, report_name, table_name, row_name, column_name, units = '*')
    # Define the query
    query = "Select Value FROM TabularDataWithStrings WHERE
    ReportName = '#{report_name}' AND
    TableName = '#{table_name}' AND
    RowName = '#{row_name}' AND
    ColumnName = '#{column_name}' AND
    Units = '#{units}'"
    # Run the query if the expected output is a string
    return model.sqlFile.get.execAndReturnFirstString(query).get unless !units.empty?

    # Run the query if the expected output is a double
    return model.sqlFile.get.execAndReturnFirstDouble(query).get
  end

  # Identify individual prototypes to be created
  #
  # @param tests [Array] Names of the tests to be performed
  # @param prototype_list [Hash] List of prototypes needed for each test
  #
  # @return [Hash] Prototypes to be generated
  def get_prototype_to_generate(tests, prototype_list)
    # Initialize prototype identifier
    id = 0
    # Associate model description to identifiers
    prototypes_to_generate = {}
    prototype_list.each do |utest, prototypes|
      prototypes.each do |prototype|
        if !prototypes_to_generate.values.include?(prototype) && tests.include?(utest)
          prototypes_to_generate[id] = prototype
          id += 1
        end
      end
    end
    return prototypes_to_generate
  end

  # Assign prototypes to each individual tests
  #
  # @param prototypes_generated [Hash] Hash containing all the OpenStudio model objects of the prototypes that have been created
  # @param tests [Array] List of tests to be performed
  # @param id_prototype_mapping [Hash] Mapping of prototypes to their respective ids
  #
  # @return [Hash] Association of OpenStudio model object to model description for each test
  def assign_prototypes(prototypes_generated, tests, id_prototype_mapping)
    test_prototypes = {}
    tests.each do |test|
      test_prototypes[test] = {}
      @@prototype_list[test].each do |prototype|
        # Find prototype id in mapping
        prototype_id = -9999.0
        id_prototype_mapping.each do |id, prototype_description|
          if prototype_description == prototype
            prototype_id = id
          end
        end
        test_prototypes[test][prototype] = prototypes_generated[prototype_id]
      end
    end
    return test_prototypes
  end

  # Check Window-to-Wall Ratio (WWR) for the baseline models
  #
  # @param prototypes_base [Hash] Baseline prototypes
  def check_wwr(prototypes_base)
    prototypes_base.each do |prototype, model_baseline|
      building_type, template, climate_zone, mod = prototype

      # Get WWR of baseline model
      wwr_baseline = run_query_tabulardatawithstrings(model_baseline, 'InputVerificationandResultsSummary', 'Conditioned Window-Wall Ratio', 'Gross Window-Wall Ratio', 'Total', '%').to_f

      # Check WWR against expected WWR
      wwr_goal = 100 * @@wwr_values[building_type].to_f
      assert(wwr_baseline == wwr_goal, "Baseline WWR for the #{building_type}, #{template}, #{climate_zone} model is incorrect. The WWR of the baseline model is #{wwr_baseline} but should be #{wwr_goal}.")
    end
  end

  # Check that no daylighting controls are modeled in the baseline models
  #
  # @param prototypes_base [Hash] Baseline prototypes
  def check_daylighting_control(prototypes_base)
    prototypes_base.each do |prototype, model_baseline|
      building_type, template, climate_zone, mod = prototype
      # Check the model include daylighting control objects
      model_baseline.getSpaces.sort.each do |space|
        existing_daylighting_controls = space.daylightingControls
        assert(existing_daylighting_controls.empty?, "The baseline model for the #{building_type}-#{template} in #{climate_zone} has daylighting control.")
      end
    end
  end

  # Check if the IsResidential flag used by the PRM works as intended (i.e. should be false for commercial spaces)
  #
  # @param prototypes_base [Hash] Baseline prototypes
  def check_residential_flag(prototypes_base)
    prototypes_base.each do |prototype, model_baseline|
      building_type, template, climate_zone, mod = prototype
      # Determine whether any space is residential
      has_res = 'false'
      std = Standard.build("#{template}_#{building_type}")
      model_baseline.getSpaces.sort.each do |space|
        if std.space_residential?(space)
          has_res = 'true'
        end
      end
      # Check whether space_residential? function is working
      has_res_goal = @@hasres_values[building_type]
      assert(has_res == has_res_goal, "Failure to set space_residential? for #{building_type}, #{template}, #{climate_zone}.")
    end
  end

  # Check envelope requirements lookups
  #
  # @param prototypes_base [Hash] Baseline prototypes
  #
  # TODO: Add residential and semi-heated spaces lookup
  def check_envelope(prototypes_base)
    prototypes_base.each do |prototype, model_baseline|
      building_type, template, climate_zone, mod = prototype
      # Define name of surfaces used for verification
      run_id = "#{building_type}_#{template}_#{climate_zone}_#{mod}"
      opaque_exterior_name = JSON.parse(File.read("#{@@json_dir}/envelope.json"))[run_id]['opaque_exterior_name']
      exterior_fenestration_name = JSON.parse(File.read("#{@@json_dir}/envelope.json"))[run_id]['exterior_fenestration_name']
      exterior_door_name = JSON.parse(File.read("#{@@json_dir}/envelope.json"))[run_id]['exterior_door_name']

      # Get U-value of envelope in baseline model
      u_value_baseline = {}
      construction_baseline = {}
      opaque_exterior_name.each do |val|
        u_value_baseline[val[0]] = run_query_tabulardatawithstrings(model_baseline, 'EnvelopeSummary', 'Opaque Exterior', val[0], 'U-Factor with Film', 'W/m2-K').to_f
        construction_baseline[val[0]] = run_query_tabulardatawithstrings(model_baseline, 'EnvelopeSummary', 'Opaque Exterior', val[0], 'Construction', '').to_s
      end
      exterior_fenestration_name.each do |val|
        u_value_baseline[val[0]] = run_query_tabulardatawithstrings(model_baseline, 'EnvelopeSummary', 'Exterior Fenestration', val[0], 'Glass U-Factor', 'W/m2-K').to_f
        construction_baseline[val[0]] = run_query_tabulardatawithstrings(model_baseline, 'EnvelopeSummary', 'Exterior Fenestration', val[0], 'Construction', '').to_s
      end
      exterior_door_name.each do |val|
        u_value_baseline[val[0]] = run_query_tabulardatawithstrings(model_baseline, 'EnvelopeSummary', 'Exterior Door', val[0], 'U-Factor with Film', 'W/m2-K').to_f
        construction_baseline[val[0]] = run_query_tabulardatawithstrings(model_baseline, 'EnvelopeSummary', 'Exterior Door', val[0], 'Construction', '').to_s
      end

      # Check U-value against expected U-value
      u_value_goal = opaque_exterior_name + exterior_fenestration_name + exterior_door_name
      u_value_goal.each do |key, value|
        value_si = OpenStudio.convert(value, 'Btu/ft^2*hr*R', 'W/m^2*K').get
        assert(((u_value_baseline[key] - value_si).abs < 0.001 || u_value_baseline[key] == 5.838), "Baseline U-value for the #{building_type}, #{template}, #{climate_zone} model is incorrect. The U-value of the #{key} is #{u_value_baseline[key]} but should be #{value_si}.")
        if key != 'PERIMETER_ZN_3_WALL_NORTH_DOOR1'
          assert((construction_baseline[key].include? 'PRM'), "Baseline U-value for the #{building_type}, #{template}, #{climate_zone} model is incorrect. The construction of the #{key} is #{construction_baseline[key]}, which is not from PRM_Construction tab.")
        end
      end
    end
  end

  # Check LPD requirements lookups
  #
  # @param prototypes_base [Hash] Baseline prototypes
  def check_lpd(prototypes_base)
    prototypes_base.each do |prototype, model_baseline|
      building_type, template, climate_zone, mod = prototype
      # Define name of spaces used for verification
      run_id = "#{building_type}_#{template}_#{climate_zone}_#{mod}"
      space_name = JSON.parse(File.read("#{@@json_dir}/lpd.json"))[run_id]

      # Get LPD in baseline model
      lpd_baseline = {}
      space_name.each do |val|
        lpd_baseline[val[0]] = run_query_tabulardatawithstrings(model_baseline, 'LightingSummary', 'Interior Lighting', val[0], 'Lighting Power Density', 'W/m2').to_f
      end

      # Check LPD against expected LPD
      space_name.each do |key, value|
        value_si = OpenStudio.convert(value, 'W/ft^2', 'W/m^2').get
        assert(((lpd_baseline[key] - value_si).abs < 0.001), "Baseline U-value for the #{building_type}, #{template}, #{climate_zone} model is incorrect. The U-value of the #{key} is #{lpd_baseline[key]} but should be #{value_si}.")
      end
    end
  end

  # Check baseline infiltration calculations
  #
  # @param prototypes_base [Hash] Baseline prototypes
  def check_infiltration(prototypes_base)
    std = Standard.build('90.1-PRM-2019')
    space_env_areas = JSON.parse(File.read("#{@@json_dir}/space_envelope_areas.json"))

    # Check that the model_get_infiltration_method and
    # model_get_infiltration_coefficients method retrieve
    # the correct information
    model_blank = OpenStudio::Model::Model.new
    infil_object = OpenStudio::Model::SpaceInfiltrationDesignFlowRate.new(model_blank)
    infil_object.setFlowperExteriorWallArea(0.001)
    infil_object.setConstantTermCoefficient(0.002)
    infil_object.setTemperatureTermCoefficient(0.003)
    infil_object.setVelocityTermCoefficient(0.004)
    infil_object.setVelocitySquaredTermCoefficient(0.005)
    new_space = OpenStudio::Model::Space.new(model_blank)
    infil_object.setSpace(new_space)
    assert(infil_object.designFlowRateCalculationMethod.to_s == std.model_get_infiltration_method(model_blank), 'Error in infiltration method retrieval.')
    assert(std.model_get_infiltration_coefficients(model_blank) == [infil_object.constantTermCoefficient,
                                                                    infil_object.temperatureTermCoefficient,
                                                                    infil_object.velocityTermCoefficient,
                                                                    infil_object.velocitySquaredTermCoefficient], 'Error in infiltration coeffcient retrieval.')

    prototypes_base.each do |prototype, model|
      building_type, template, climate_zone, mod = prototype
      run_id = "#{building_type}_#{template}_#{climate_zone}_#{mod}"

      # Check if the space envelope area calculations
      spc_env_area = 0
      model.getSpaces.sort.each do |spc|
        spc_env_area += std.space_envelope_area(spc, climate_zone)
      end
      assert((space_env_areas[run_id].to_f - spc_env_area.round(2)).abs < 0.001, "Space envelope calculation is incorrect for the #{building_type}, #{template}, #{climate_zone} model: #{spc_env_area} (model) vs. #{space_env_areas[run_id]} (expected).")

      # Check that infiltrations are not assigned at
      # the space type level
      model.getSpaceTypes.sort.each do |spc|
        assert(false, "The baseline for the #{building_type}, #{template}, #{climate_zone} model has infiltration specified at the space type level.") unless spc.spaceInfiltrationDesignFlowRates.empty?
      end

      # Back calculate the I_75 (cfm/ft2), expected value is 1 cfm/ft2 in 90.1-PRM-2019
      conv_fact = OpenStudio.convert(1, 'm^3/s', 'ft^3/min').to_f / OpenStudio.convert(1, 'm^2', 'ft^2').to_f
      assert((std.model_current_building_envelope_infiltration_at_75pa(model, spc_env_area) * conv_fact).round(2) == 1.0, 'The baseline air leakage rate of the building envelope at a fixed building pressure of 75 Pa is different that the requirement (1 cfm/ft2).')
    end
  end

  # Run test suite for the ASHRAE 90.1 appendix G Performance
  # Rating Method (PRM) baseline automation implementation
  # in openstudio-standards.
  def test_create_prototype_baseline_building
    # Select test to run
    tests = [
      'wwr',
      'envelope',
      'lpd',
      'isresidential',
      'daylighting_control',
      'infiltration'
    ]

    # Get list of unique prototypes
    prototypes_to_generate = get_prototype_to_generate(tests, @@prototype_list)
    # Generate all unique prototypes
    prototypes_generated = generate_prototypes(prototypes_to_generate)
    # Create all unique baseline
    prototypes_baseline_generated = generate_baseline(prototypes_generated, prototypes_to_generate)
    # Assign prototypes and baseline to each test
    prototypes = assign_prototypes(prototypes_baseline_generated, tests, prototypes_to_generate)
    prototypes_base = assign_prototypes(prototypes_baseline_generated, tests, prototypes_to_generate)

    # Run tests
    check_wwr(prototypes_base['wwr']) unless !(tests.include? 'wwr')
    check_daylighting_control(prototypes_base['daylighting_control']) unless !(tests.include? 'daylighting_control')
    check_residential_flag(prototypes_base['isresidential']) unless !(tests.include? 'isresidential')
    check_envelope(prototypes_base['envelope']) unless !(tests.include? 'envelope')
    check_lpd(prototypes_base['lpd']) unless !(tests.include? 'lpd')
    check_infiltration(prototypes_base['infiltration']) unless !(tests.include? 'infiltration')
  end
end
