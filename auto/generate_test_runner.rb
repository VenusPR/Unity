# ==========================================
#   Unity Project - A Test Framework for C
#   Copyright (c) 2007 Mike Karlesky, Mark VanderVoord, Greg Williams
#   [Released under MIT License. Please refer to license.txt for details]
# ========================================== 

File.expand_path(File.join(File.dirname(__FILE__),'colour_prompt'))

class UnityTestRunnerGenerator

  def initialize(options = nil)
    @options = { :includes => [], :framework => :unity }
    case(options)
      when NilClass then @options
      when String   then @options = UnityTestRunnerGenerator.grab_config(options)
      when Hash     then @options = options
      else          raise "If you specify arguments, it should be a filename or a hash of options"
    end
  end
  
  def self.grab_config(config_file)
    options = { :includes => [], :framework => :unity }
    unless (config_file.nil? or config_file.empty?)
      require 'yaml'
      yaml_guts = YAML.load_file(config_file)
      yaml_goodness = yaml_guts[:unity] ? yaml_guts[:unity] : yaml_guts[:cmock]
      options[:cexception] = 1 unless (yaml_goodness[:plugins] & ['cexception', :cexception]).empty?
      options[:coverage  ] = 1 if     (yaml_goodness[:coverage])
      options[:order]      = 1 if     (yaml_goodness[:enforce_strict_ordering])
      options[:framework]  =          (yaml_goodness[:framework] || :unity)
      options[:includes]   <<         (yaml_goodness[:includes])
    end
    return(options)
  end

  def run(input_file, output_file, options=nil)
    tests = []
    includes = []
    used_mocks = []
    
    @options = options unless options.nil?
    module_name = File.basename(input_file)
    
    #pull required data from source file
    File.open(input_file, 'r') do |input|
      tests      = find_tests(input)
      includes   = find_includes(input)
      used_mocks = find_mocks(includes)
    end
    
    puts "Creating test runner for #{module_name}..."

    #build runner file
    File.open(output_file, 'w') do |output|
      create_header(output, used_mocks)
      create_externs(output, tests, used_mocks)
      create_mock_management(output, used_mocks)
      create_runtest(output, used_mocks)
	    create_reset(output, used_mocks)
      create_main(output, input_file, tests)
    end
    
    all_files_used = [input_file, output_file]
    all_files_used += includes.map {|filename| filename + '.c'} unless includes.empty?
    all_files_used += @options[:includes] unless @options[:includes].empty?
    return all_files_used.uniq
  end
  
  def find_tests(input_file)
    tests_raw = []
    tests_and_line_numbers = []
    
    input_file.rewind
    source_raw = input_file.read
    source_scrubbed = source_raw.gsub(/\/\/.*$/, '') #remove line comments
    source_scrubbed = source_scrubbed.gsub(/\/\*.*?\*\//m, '') #remove block comments
    lines = source_scrubbed.split(/(^\s*\#.*$)  # Treat preprocessor directives as a logical line
                              | (;|\{|\}) /x) # Match ;, {, and } as end of lines

    lines.each_with_index do |line, index|
      if line =~ /^\s*void\s+test(.*?)\s*\(\s*void\s*\)/
        tests_raw << ("test" + $1)
      end
    end

    source_lines = source_raw.split("\n")
    source_index = 0;

    tests_raw.each do |test|
      source_lines[source_index..-1].each_with_index do |line, index|
        if (line =~ /#{test}/)
          source_index += index
          tests_and_line_numbers << {:name => test, :line_number => (source_index+1)}
          break
        end
      end
    end
    return tests_and_line_numbers
  end

  def find_includes(input_file)
    input_file.rewind
    includes = []
    input_file.readlines.each do |line|
      scan_results = line.scan(/^#include\s+\"\s*(.+)\.h\s*\"/)
      includes << scan_results[0][0] if (scan_results.size > 0)
    end
    return includes
  end
  
  def find_mocks(includes)
    mock_headers = []
    includes.each do |include_file|
      mock_headers << File.basename(include_file) if (include_file =~ /^mock/i)
    end
    return mock_headers  
  end
  
  def create_header(output, mocks)
    output.puts('/* AUTOGENERATED FILE. DO NOT EDIT. */')
    output.puts("#include \"#{@options[:framework].to_s}.h\"")
    output.puts('#include "cmock.h"') unless (mocks.empty?)
    @options[:includes].flatten.each do |includes|
      output.puts("#include \"#{includes.gsub('.h','')}.h\"")
    end
    output.puts('#include <setjmp.h>')
    output.puts('#include <stdio.h>')
    output.puts('#include "CException.h"') if @options[:cexception]
    output.puts('#include "BullseyeCoverage.h"') if @options[:coverage]
    mocks.each do |mock|
      output.puts("#include \"#{mock.gsub('.h','')}.h\"")
    end
    output.puts('')    
    output.puts('char MessageBuffer[50];')
    if @options[:order]
      output.puts('int GlobalExpectCount;') 
      output.puts('int GlobalVerifyOrder;') 
      output.puts('char* GlobalOrderError;') 
    end
  end
  
  
  def create_externs(output, tests, mocks)
    output.puts('')
    output.puts("extern void setUp(void);")
    output.puts("extern void tearDown(void);")
    output.puts('')
    tests.each do |test|
      output.puts("extern void #{test[:name]}(void);")
    end
    output.puts('')
  end
  
  
  def create_mock_management(output, mocks)
    unless (mocks.empty?)
      output.puts("static void CMock_Init(void)")
      output.puts("{")
      if @options[:order]
        output.puts("  GlobalExpectCount = 0;")
        output.puts("  GlobalVerifyOrder = 0;") 
        output.puts("  GlobalOrderError = NULL;") 
      end
      mocks.each do |mock|
        output.puts("  #{mock}_Init();")
      end
      output.puts("}\n")

      output.puts("static void CMock_Verify(void)")
      output.puts("{")
      mocks.each do |mock|
        output.puts("  #{mock}_Verify();")
      end
      output.puts("}\n")

      output.puts("static void CMock_Destroy(void)")
      output.puts("{")
      mocks.each do |mock|
        output.puts("  #{mock}_Destroy();")
      end
      output.puts("}\n")
    end
  end
  
  
  def create_runtest(output, used_mocks)
    output.puts("static void runTest(UnityTestFunction test)")
    output.puts("{")
    output.puts("  if (TEST_PROTECT())")
    output.puts("  {")
    output.puts("    CEXCEPTION_T e;") if @options[:cexception]
    output.puts("    Try {") if @options[:cexception]
    output.puts("      CMock_Init();") unless (used_mocks.empty?) 
    output.puts("      setUp();")
    output.puts("      test();")
    output.puts("      CMock_Verify();") unless (used_mocks.empty?)
    output.puts("    } Catch(e) { TEST_ASSERT_EQUAL_HEX32_MESSAGE(CEXCEPTION_NONE, e, \"Unhandled Exception!\"); }") if @options[:cexception]
    output.puts("  }")
    output.puts("  CMock_Destroy();") unless (used_mocks.empty?)
    output.puts("  if (TEST_PROTECT() && !TEST_IS_IGNORED)")
    output.puts("  {")
    output.puts("    tearDown();")
    output.puts("  }")
    output.puts("}")
  end
  
  def create_reset(output, used_mocks)
    output.puts("void resetTest()")
    output.puts("{")
    output.puts("  CMock_Verify();") unless (used_mocks.empty?)
    output.puts("  CMock_Destroy();") unless (used_mocks.empty?)
    output.puts("  tearDown();")
    output.puts("  CMock_Init();") unless (used_mocks.empty?) 
    output.puts("  setUp();")
    output.puts("}")
  end
  
  def create_main(output, filename, tests)
    output.puts()
    output.puts()
    output.puts("int main(void)")
    output.puts("{")
    output.puts("  Unity.TestFile = \"#{filename}\";")
    output.puts("  UnityBegin();")
    output.puts()

    output.puts("  // RUN_TEST calls runTest")  	
    tests.each do |test|
      output.puts("  RUN_TEST(#{test[:name]}, #{test[:line_number]});")
    end

    output.puts()
    output.puts("  UnityEnd();")
    output.puts("  cov_write();") if @options[:coverage]
    output.puts("  return 0;")
    output.puts("}")
  end
end


if ($0 == __FILE__)
  usage = ["usage: ruby #{__FILE__} (yaml) (options) input_test_file output_test_runner (includes)",
           "  blah.yml    - will use config options in the yml file (see CMock docs)",
           "  -cexception - include cexception support",
           "  -coverage   - include bullseye coverage support",
           "  -order      - include cmock order-enforcement support" ]

  options = { :includes => [] }
  yaml_file = nil
  
  #parse out all the options first
  ARGV.reject! do |arg| 
    if (arg =~ /\-(\w+)/) 
      options[$1.to_sym] = 1
      true
    elsif (arg =~ /(\w+\.yml)/)
      options = UnityTestRunnerGenerator.grab_config(arg)
      true
    else
      false
    end
  end     
           
  #make sure there is at least one parameter left (the input file)
  if !ARGV[0]
    puts usage
    exit 1
  end
  
  #create the default test runner name if not specified
  ARGV[1] = ARGV[0].gsub(".c","_Runner.c") if (!ARGV[1])
  
  #everything else is an include file
  options[:includes] = (ARGV.slice(2..-1).flatten.compact) if (ARGV.size > 2)
  
  UnityTestRunnerGenerator.new(options).run(ARGV[0], ARGV[1])
end
