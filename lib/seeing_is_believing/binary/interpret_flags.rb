# Debugger initialization happens here
require 'seeing_is_believing/debugger'

# Alignment decision happens here
require 'seeing_is_believing/binary/align_file'
require 'seeing_is_believing/binary/align_line'
require 'seeing_is_believing/binary/align_chunk'

# Evaluator decision happens here
require 'seeing_is_believing/evaluate_by_moving_files'

# Annotator decision happens here
require 'seeing_is_believing/binary/annotate_every_line'
require 'seeing_is_believing/binary/annotate_xmpfilter_style'

class SeeingIsBelieving
  module Binary
    class InterpretFlags
      def self.to_regex(string)
        flag_to_bit = {'i' => 0b001, 'x' => 0b010, 'm' => 0b100}
        string =~ %r{\A/(.*)/([mxi]*)\Z}
        Regexp.new ($1||string),
                   ($2||"").each_char.inject(0) { |bits, flag| bits|flag_to_bit[flag] }
      end


      def self.attr_predicate(name)
        define_method("#{name}?") { predicates.fetch name }
      end
      attr_predicate :print_version
      attr_predicate :inherit_exit_status
      attr_predicate :result_as_json
      attr_predicate :print_help
      attr_predicate :print_cleaned
      attr_predicate :provided_filename_dne
      attr_predicate :file_is_on_stdin
      attr_predicate :appended_newline

      def self.attr_attribute(name)
        define_method(name) { attributes.fetch name }
      end
      attr_attribute :annotator
      attr_attribute :help_screen
      attr_attribute :debugger
      attr_attribute :markers
      attr_attribute :marker_regexes
      attr_attribute :timeout
      attr_attribute :filename
      attr_attribute :body
      attr_attribute :annotator_options
      attr_attribute :prepared_body
      attr_attribute :lib_options
      attr_attribute :errors

      def initialize(flags, stdin, stdout)
        # Some simple attributes
        self.attributes = {}
        attributes[:errors]         = flags.fetch(:errors)
        attributes[:markers]        = flags.fetch(:markers) # TODO: Should probably object-ify these
        attributes[:marker_regexes] = flags.fetch(:marker_regexes).each_with_object({}) { |(k, v), rs| rs[k] = self.class.to_regex v }
        attributes[:timeout]        = flags.fetch(:timeout) # b/c binary prints this out in the error message  TODO: rename seconds_until_timeout
        attributes[:filename]       = flags.fetch(:filename)

        # All predicates
        self.predicates = {}
        predicates[:print_version]         = flags.fetch(:version) # TODO: rename rhs to print_version ?
        predicates[:inherit_exit_status]   = flags.fetch(:inherit_exit_status)
        predicates[:result_as_json]        = flags.fetch(:result_as_json)
        predicates[:print_help]            = !!flags.fetch(:help)
        predicates[:print_cleaned]         = flags.fetch(:clean) # TODO: Better name on rhs
        predicates[:provided_filename_dne] = !!(filename && !File.exist?(filename)) # TODO: Should this just be an error in errors table?
        predicates[:file_is_on_stdin]      = (!filename && !flags.fetch(:program_from_args))

        # Polymorphism, y'all!
        attributes[:annotator]   = (flags.fetch(:xmpfilter_style) ? AnnotateXmpfilterStyle                     : AnnotateEveryLine)
        attributes[:help_screen] = flags.fetch(:help) == 'help'   ? flags.fetch(:short_help_screen)            : flags.fetch(:long_help_screen)
        attributes[:debugger]    = flags.fetch(:debug)            ? Debugger.new(stream: stdout, colour: true) : Debugger.new(stream: nil)
        attributes[:body]        = ((print_version? || print_help?) && String.new)    ||
                                   flags.fetch(:program_from_args)                    ||
                                   (file_is_on_stdin? && stdin.read)                  ||
                                   (File.read filename unless provided_filename_dne?) ||
                                   String.new

        # Attributes that depend on predicates
        if body.end_with? "\n"
          predicates[:appended_newline] = false
          body_with_nl                  = body
        else
          predicates[:appended_newline] = true
          body_with_nl                  = body + "\n"
        end
        attributes[:prepared_body] = annotator.prepare_body(body_with_nl, marker_regexes)

        # The lib's options (passed to SeeingIsBelieving.new)
        attributes[:lib_options] = {
          filename:           (flags.fetch(:as) || filename),
          stdin:              (file_is_on_stdin? ? '' : stdin),
          require:            (['seeing_is_believing/the_matrix'] + flags.fetch(:require)), # TODO: rename requires: files_to_require, or :requires or maybe :to_require
          load_path:          ([File.expand_path('../../..', __FILE__)] + flags.fetch(:load_path)),
          encoding:           flags.fetch(:encoding),
          timeout:            timeout,
          debugger:           debugger,
          number_of_captures: flags.fetch(:number_of_captures), # TODO: Rename to max_number_of_captures
          annotate:           annotator.expression_wrapper(markers, marker_regexes), # TODO: rename to wrap_expressions
        }

        # The annotator's options (passed to annotator.call)
        attributes[:annotator_options] = {
          alignment_strategy: extract_alignment_strategy(flags.fetch(:alignment_strategy), errors),
          debugger:           debugger,
          markers:            markers,
          marker_regexes:     marker_regexes,
          max_line_length:    flags.fetch(:max_line_length),
          max_result_length:  flags.fetch(:max_result_length),
        }

        # Some error checking
        if 1 < flags.fetch(:filenames).size
          errors << "Can only have one filename, but had: #{flags.fetch(:filenames).map(&:inspect).join ', '}"
        elsif filename && flags.fetch(:program_from_args)
          errors << "You passed the program in an argument, but have also specified the filename #{filename.inspect}"
        end
      end

      def inspect
        inspected = "#<#{self.class.name.inspect}\n"
        inspected << "  --PREDICATES--\n"
        predicates.each do |predicate, value|
          inspected << inspect_line(sprintf "    %-25s %p", predicate.to_s+"?", value)
        end
        inspected << "  --ATTRIBUTES--\n"
        attributes.each do |predicate, value|
          inspected << inspect_line(sprintf "    %-20s %p", predicate.to_s, value)
        end
        inspected << ">"
        inspected
      end

      private

      attr_accessor :predicates, :attributes

      def extract_alignment_strategy(strategy_name, errors)
        strategies = {'file' => AlignFile, 'chunk' => AlignChunk, 'line' => AlignLine}
        if strategies[strategy_name]
          strategies[strategy_name]
        elsif strategy_name
          errors << "alignment-strategy does not know #{strategy_name}, only knows: #{strategies.keys.join(', ')}"
        else
          errors << "alignment-strategy expected an alignment strategy as the following argument but did not see one"
        end
      end

      def inspect_line(line)
        if line.size < 78
          line << "\n"
        else
          line[0, 75] << "...\n"
        end
      end
    end
  end
end
