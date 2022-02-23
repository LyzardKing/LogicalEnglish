/* le_input: a prolog module with predicates to translate from an 
extended version of Logical English into the Prolog or Taxlog
programming languages.   

Copyright [2021] Initial copyright holders by country: 
LodgeIT (AU), AORA Law (UK), Bob Kowalski (UK), Miguel Calejo (PT), Jacinto Dávila (VE)

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

Main predicate: text_to_logic(String to be translated, Translation)

Main DCG nonterminal: document(Translation)

See at the end the predicate le_taxlog_translate to be used from SWISH

It assumes an entry with the following structure. One of these expressions:

the meta predicates are:
the predicates are:
the templates are:
the timeless predicates are:
the event predicates are:
the fluents are:
the time-varying predicates are:

followed by the declarations of all the corresponding predicates mentioned in the 
knowledge base. 

Each declarations define a template with the variables and other words required to
describe a relevant relation. It is a comma separated list of templates which ends
with a period. 

After that period, one of the following statement introduces the knowledge base:

the knowledge base includes: 
the knowledge base <Name> includes: 

And it is followed by the rules and facts written in Logical English syntax. 
Each rule must end with a period. 

Indentation is used to organize the and/or list of conditions by strict
observance of one condition per line with a level of indentation that 
corresponds to each operator and corresponding conditions. 

Similarly, there may be sections for scenarios and queries, like:

--
scenario test2 is:
   borrower pays an amount to lender on 2015-06-01T00:00:00. 
--

and

--
query one is:
for which event:
 the small business restructure rollover applies to the event.

query two is:
 which tax payer is a party of which event.

query three is:
 A first time is after a second time
 and the second time is immediately before the first time.
--

 which can then be used on the new command interface of LE on SWISH
(e.g. answer/1 and others querying predicates):

? answer("query one with scenario test"). 

*/

:- module(le_input, 
    [document/3, le_taxlog_translate/4, 
    op(1000,xfy,user:and),  % to support querying
    op(800,fx,user:resolve), % to support querying
    op(800,fx,user:answer), % to support querying
    op(800,fx,user:répondre), % to support querying in french
    op(850,xfx,user:with), % to support querying
    op(850,xfx,user:avec), % to support querying in french
    op(800,fx,user:risposta), % to support querying in italian
    op(850,xfx,user:con), % to support querying in italian
    op(800,fx,user:show), % to support querying
    op(850,xfx,user:of), % to support querying
    op(850,fx,user:'#pred'), % to support scasp 
    op(800,xfx,user:'::'), % to support scasp 
    dictionary/3, meta_dictionary/3,
    translate_goal_into_LE/2, name_as_atom/2, parsed/0, source_lang/1, 
    dump/4, dump/3, dump/2
    ]).
:- use_module('./tokenize/prolog/tokenize.pl').
:- use_module(library(pengines)).
:- use_module('reasoner.pl').
:- use_module(kp_loader).
:- use_module(library(prolog_stack)).
:- thread_local text_size/1, error_notice/4, dict/3, meta_dict/3, example/2, local_dict/3, local_meta_dict/3,
                last_nl_parsed/1, kbname/1, happens/2, initiates/3, terminates/3, is_type/1,
                predicates/1, events/1, fluents/1, metapredicates/1, parsed/0, source_lang/1.  
:- discontiguous statement/3, declaration/4, example/2. 

% Main clause: text_to_logic(+String,-Clauses) is det
% Errors are added to error_notice 
% text_to_logic/2
text_to_logic(String_, Translation) :-
    % hack to ensure a newline at the end, for the sake of error reporting:
    ((sub_atom(String_,_,1,0,NL), memberchk(NL,['\n','\r']) ) -> String=String_ ; atom_concat(String_,'\n',String)),
    tokenize(String, Tokens, [cased(true), spaces(true), numbers(false)]),
    retractall(last_nl_parsed(_)), asserta(last_nl_parsed(1)), % preparing line counting
    unpack_tokens(Tokens, UTokens), 
    clean_comments(UTokens, CTokens), !, 
    %print_message(informational, "Tokens: ~w"-[CTokens]), 
    phrase(document(Translation), CTokens). 
    %( phrase(document(Translation), CTokens) -> 
    %    ( print_message(informational, "Translation: ~w"-[Translation]) )
    %;   ( print_message(informational, "Translation failed: "-[]), Translation=[], fail)). 

% document/3 (or document/1 in dcg)
document(Translation, In, Rest) :- 
    (parsed -> retract(parsed); true), 
    (source_lang(L) -> retract(source_lang(L)) ; true),
    phrase(header(Settings), In, AfterHeader), !, %print_message(informational, "Declarations completed: ~w"-[Settings]), 
    phrase(content(Content), AfterHeader, Rest), 
    append(Settings, Content, Translation), !,  
    assertz(parsed). 

% header parses all the declarations and assert them into memory to be invoked by the rules. 
% header/3
header(Settings, In, Next) :-
    length(In, TextSize), % after comments were removed
    ( phrase(settings(DictEntries, Settings_), In, Next) -> 
        ( member(target(_), Settings_) -> Settings1 = Settings_ ; Settings1 = [target(taxlog)|Settings_] )  % taxlog as default
    ; (DictEntries = [], Settings1 = [target(taxlog)] ) ), % taxlog as default
    Settings = [query(null, true), example(null, [])|Settings1], % a hack to stop the loop when query is empty
    RulesforErrors = % rules for errors that have been statically added
      [(text_size(TextSize))|Settings], % is text_size being used? % asserting the Settings too! predicates, events and fluents
    order_templates(DictEntries, OrderedEntries), 
    process_types_dict(OrderedEntries, Types), 
    %print_message(informational, Types),
    append(OrderedEntries, RulesforErrors, SomeRules),
    append(SomeRules, Types, MRules), 
    assertall(MRules), !. % asserting contextual information
header(_, Rest, _) :- 
    asserterror('LE error in the header ', Rest), 
    fail.

% Experimental rules for processing types:
process_types_dict(Dictionary, Type_entries) :- 
    findall(Word, 
    (   (member(dict([_|GoalElements], Types, _), Dictionary);
        member(meta_dict([_|GoalElements], Types, _), Dictionary)), 
        member((_Name-Type), Types), 
        process_types_or_names([Type], GoalElements, Types, TypeWords),
        concat_atom(TypeWords, '_', Word), Word\=''), Templates), 
    setof(is_type(Ty), member(Ty, Templates), Type_entries).

% Experimental rules for reordering of templates
% order_templates/2
order_templates(NonOrdered, Ordered) :-
	predsort(compare_templates, NonOrdered, Ordered).

compare_templates(<, meta_dict(_,_,_), dict(_,_,_)). 

compare_templates(=, dict(_,_,T1), dict(_,_,T2)) :- T1 =@= T2. 
compare_templates(<, dict(_,_,T1), dict(_,_,T2)) :- length(T1, N1), length(T2, N2), N1>N2. 
compare_templates(<, dict(_,_,T1), dict(_,_,T2)) :- length(T1, N), length(T2, N), template_before(T1, T2).  

compare_templates(>, Dict1, Dict2) :- not(compare_templates(=, Dict1, Dict2)), not(compare_templates(<, Dict1, Dict2)). 

compare_templates(=, meta_dict(_,_,T1), meta_dict(_,_,T2)) :- T1 =@= T2. 
compare_templates(<, meta_dict(_,_,T1), meta_dict(_,_,T2)) :- length(T1, N1), length(T2, N2), N1>N2. 
compare_templates(<, meta_dict(_,_,T1), meta_dict(_,_,T2)) :- length(T1, N), length(T2, N), template_before(T1, T2).  

template_before([H1], [H2]) :- H1 =@= H2. 
template_before([H1|_R1], [H2|_R2]) :- nonvar(H1), var(H2).
template_before([H1|_R1], [H2|_R2]) :- H1 @> H2. 
template_before([H1|R1], [H2|R2]) :- H1=@=H2, template_before(R1, R2). 


/* --------------------------------------------------------- LE DCGs */
% settings/2 or /4
settings(AllR, AllS) --> 
    spaces_or_newlines(_), declaration(Rules,Setting), settings(RRules, RS), 
    {append(Setting, RS, AllS), append(Rules, RRules, AllR)}, !.
settings([], [], Stay, Stay) :-
    ( phrase(rules_previous(_), Stay, _) ; 
      phrase(scenario_, Stay, _)  ;  
      phrase(query_, Stay, _) ), !.  
    % settings ending with the start of the knowledge base or scenarios or queries. 
settings(_, _, Rest, _) :- 
    asserterror('LE error in the declarations ', Rest), 
    fail.
settings([], [], Stay, Stay).

% content structure: cuts added to avoid search loop
% content/1 or /3
content(T) --> %{print_message(informational, "going for KB:"-[])},  
    spaces_or_newlines(_), rules_previous(Kbname), %{print_message(informational, "KBName: ~w"-[Kbname])}, 
    kbase_content(S),  %{print_message(informational, "KB: ~w"-[S])}, 
    content(R), 
    {append([kbname(Kbname)|S], R, T)}, !.
content(T) --> %{print_message(informational, "going for scenario:"-[])},
    spaces_or_newlines(_), scenario_content(S), !, %{print_message(informational, "scenario: ~w"-[S])},
    content(R), 
    {append(S, R, T)}, !.
content(T) --> %{print_message(informational, "going for query:"-[])},
    spaces_or_newlines(_), query_content(S), !, content(R), 
    {append(S, R, T)}, !.
content([]) --> 
    spaces_or_newlines(_), []. 
content(_, Rest, _) :- 
    asserterror('LE error in the content ', Rest), 
    fail.

% kbase_content/1 or /3
kbase_content(T) --> 
    spaces_or_newlines(_),  statement(S),  kbase_content(R),
    {append(S, R, T)}, !. 
kbase_content([]) --> 
    spaces_or_newlines(_), [].
kbase_content(_, Rest, _) :- 
    asserterror('LE error in a knowledge base ', Rest), 
    fail.

% declaration/2 or /4
% target
declaration([], [target(Language)]) --> % one word description for the language: prolog, taxlog
    spaces(_), [the], spaces(_), [target], spaces(_), [language], spaces(_), [is], spaces(_), colon_or_not_, 
    spaces(_), [Language], spaces(_), period, !, {assertz(source_lang(en))}.
% french: la langue cible est : prolog 
declaration([], [target(Language)]) --> % one word description for the language: prolog, taxlog
    spaces(_), [la], spaces(_), [langue], spaces(_), [cible], spaces(_), [est], spaces(_), colon_or_not_, 
    spaces(_), [Language], spaces(_), period, !, {assertz(source_lang(fr))}.
% italiano: il linguaggio destinazione è : prolog 
declaration([], [target(Language)]) --> % one word description for the language: prolog, taxlog
    spaces(_), [il], spaces(_), [linguaggio], spaces(_), [destinazione], spaces(_), [è], spaces(_), colon_or_not_, 
    spaces(_), [Language], spaces(_), period, !, {assertz(source_lang(it))}.

% meta predicates
declaration(Rules, [metapredicates(MetaTemplates)]) -->
    meta_predicate_previous, list_of_meta_predicates_decl(Rules, MetaTemplates), !.
%timeless 
declaration(Rules, [predicates(Templates)]) -->
    predicate_previous, list_of_predicates_decl(Rules, Templates), !.
%events
declaration(Rules, [events(EventTypes)]) -->
    event_predicate_previous, list_of_predicates_decl(Rules, EventTypes), !.
%time varying
declaration(Rules, [fluents(Fluents)]) -->
    fluent_predicate_previous, list_of_predicates_decl(Rules, Fluents), !.
%
declaration(_, _, Rest, _) :- 
    asserterror('LE error in a declaration ', Rest), 
    fail.

colon_or_not_ --> [':'], spaces(_).
colon_or_not_ --> []. 

meta_predicate_previous --> 
    spaces(_), [the], spaces(_), [metapredicates], spaces(_), [are], spaces(_), [':'], spaces_or_newlines(_).
meta_predicate_previous --> 
    spaces(_), [the], spaces(_), [meta], spaces(_), [predicates], spaces(_), [are], spaces(_), [':'], spaces_or_newlines(_).
meta_predicate_previous --> 
    spaces(_), [the], spaces(_), [meta], spaces(_), ['-'], spaces(_), [predicates], spaces(_), [are], spaces(_), [':'], spaces_or_newlines(_).

predicate_previous --> 
    spaces(_), [the], spaces(_), [predicates], spaces(_), [are], spaces(_), [':'], spaces_or_newlines(_).
predicate_previous --> 
    spaces(_), [the], spaces(_), [templates], spaces(_), [are], spaces(_), [':'], spaces_or_newlines(_).
predicate_previous --> 
    spaces(_), [the], spaces(_), [timeless], spaces(_), [predicates], spaces(_), [are], spaces(_), [':'], spaces_or_newlines(_).
% french : les modèles sont :
predicate_previous --> 
    spaces(_), [les], spaces(_), ['modèles'], spaces(_), [sont], spaces(_), [':'], spaces_or_newlines(_).
% italian: i predicati sono:
predicate_previous --> 
    spaces(_), [i], spaces(_), [modelli], spaces(_), [sono], spaces(_), [':'], spaces_or_newlines(_).

event_predicate_previous --> 
    spaces(_), [the], spaces(_), [event], spaces(_), [predicates], spaces(_), [are], spaces(_), [':'], spaces_or_newlines(_).

fluent_predicate_previous --> 
    spaces(_), [the], spaces(_), [fluents], spaces(_), [are], spaces(_), [':'], spaces_or_newlines(_).
fluent_predicate_previous --> 
    spaces(_), [the], spaces(_), [time], ['-'], [varying], spaces(_), [predicates], spaces(_), [are], spaces(_), [':'], spaces_or_newlines(_).

% at least one predicate declaration required
list_of_predicates_decl([], []) --> spaces_or_newlines(_), next_section, !. 
list_of_predicates_decl([Ru|Rin], [F|Rout]) --> spaces_or_newlines(_), predicate_decl(Ru,F), comma_or_period, list_of_predicates_decl(Rin, Rout), !.
list_of_predicates_decl(_, _, Rest, _) :- 
    asserterror('LE error found in a declaration ', Rest), 
    fail.

% at least one predicate declaration required
list_of_meta_predicates_decl([], []) --> spaces_or_newlines(_), next_section, !. 
list_of_meta_predicates_decl([Ru|Rin], [F|Rout]) --> 
    spaces_or_newlines(_), meta_predicate_decl(Ru,F), comma_or_period, list_of_meta_predicates_decl(Rin, Rout).
list_of_meta_predicates_decl(_, _, Rest, _) :- 
    asserterror('LE error found in the declaration of a meta template ', Rest), 
    fail.

% next_section/2
% a hack to avoid superflous searches  format(string(Mess), "~w", [StopHere]), print_message(informational, Message), 
next_section(StopHere, StopHere)  :-
    phrase(meta_predicate_previous, StopHere, _), !. % format(string(Message), "Next meta predicates", []), print_message(informational, Message).

next_section(StopHere, StopHere)  :-
    phrase(predicate_previous, StopHere, _), !. % format(string(Message), "Next predicates", []), print_message(informational, Message).

next_section(StopHere, StopHere)  :-
    phrase(event_predicate_previous, StopHere, _), !. % format(string(Message), "Next ecent predicates", []), print_message(informational, Message).

next_section(StopHere, StopHere)  :-
    phrase(fluent_predicate_previous, StopHere, _), !. % format(string(Message), "Next fluents", []), print_message(informational, Message).

next_section(StopHere, StopHere)  :-
    phrase(rules_previous(_), StopHere, _), !. % format(string(Message), "Next knowledge base", []), print_message(informational, Message).

next_section(StopHere, StopHere)  :-
    phrase(scenario_, StopHere, _), !. % format(string(Message), "Next scenario", []), print_message(informational, Message).

next_section(StopHere, StopHere)  :-
    phrase(query_, StopHere, _).  % format(string(Message), "Next query", []), print_message(informational, Message).

% predicate_decl/2
predicate_decl(dict([Predicate|Arguments],TypesAndNames, Template), Relation) -->
    spaces(_), template_decl(RawTemplate), 
    {build_template(RawTemplate, Predicate, Arguments, TypesAndNames, Template),
     Relation =.. [Predicate|Arguments]}, !.
% we are using this resource of the last clause to record the error and its details
% not very useful with loops, of course. 
% error clause
predicate_decl(_, _, Rest, _) :- 
    asserterror('LE error found in a declaration ', Rest), 
    fail.

% meta_predicate_decl/2
meta_predicate_decl(meta_dict([Predicate|Arguments],TypesAndNames, Template), Relation) -->
    spaces(_), template_decl(RawTemplate), 
    {build_template(RawTemplate, Predicate, Arguments, TypesAndNames, Template),
     Relation =.. [Predicate|Arguments]}.
meta_predicate_decl(_, _, Rest, _) :- 
    asserterror('LE error found in a meta template declaration ', Rest), 
    fail.

rules_previous(default) --> 
    spaces_or_newlines(_), [the], spaces(_), [rules], spaces(_), [are], spaces(_), [':'], spaces_or_newlines(_), !.
rules_previous(KBName) --> 
    spaces_or_newlines(_), [the], spaces(_), ['knowledge'], spaces(_), [base], extract_constant([includes], NameWords), [includes], spaces(_), [':'], !, spaces_or_newlines(_),
    {name_as_atom(NameWords, KBName)}.
rules_previous(default) -->  % backward compatibility
    spaces_or_newlines(_), [the], spaces(_), ['knowledge'], spaces(_), [base], spaces(_), [includes], spaces(_), [':'], spaces_or_newlines(_). 
% italian: la base di conoscenza <nome> include
rules_previous(KBName) --> 
    spaces_or_newlines(_), [la], spaces(_), [base], spaces(_), [di], spaces(_), [conoscenza], spaces(_), extract_constant([include], NameWords), [include], spaces(_), [':'], !, spaces_or_newlines(_),
    {name_as_atom(NameWords, KBName)}.
% french: la base de connaissances dont le nom est <nom> comprend :
rules_previous(KBName) --> 
    spaces_or_newlines(_), [la], spaces(_), [base], spaces(_), [de], spaces(_), [connaissances], spaces(_), [dont], spaces(_), [le], spaces(_), [nom], spaces(_), [est], extract_constant([comprend], NameWords), [comprend], spaces(_), [':'], !, spaces_or_newlines(_),
    {name_as_atom(NameWords, KBName)}.

% scenario_content/1 or /3
% a scenario description: assuming one example -> one scenario -> one list of facts.
scenario_content(Scenario) -->
    scenario_, extract_constant([is, es, est, è], NameWords), is_colon_, newline,
    %list_of_facts(Facts), period, !, 
    spaces(_), assumptions_(Assumptions), !, % period is gone
    {name_as_atom(NameWords, Name), Scenario = [example( Name, [scenario(Assumptions, true)])]}.

scenario_content(_,  Rest, _) :- 
    asserterror('LE error found around this scenario expression: ', Rest), fail.

% query_content/1 or /3
% statement: the different types of statements in a LE text
% a query
query_content(Query) -->
    query_, extract_constant([is, es, est, è], NameWords), is_colon_, spaces_or_newlines(_),
    query_header(Ind0, Map1),  
    conditions(Ind0, Map1, _, Conds), !, period,  % period stays!
    {name_as_atom(NameWords, Name), Query = [query(Name, Conds)]}. 

query_content(_, Rest, _) :- 
    asserterror('LE error found around this expression: ', Rest), fail.

% (holds_at(_149428,_149434) if 
% (happens_at(_150138,_150144),
%           initiates_at(_150138,_149428,_150144)),
%           _150144 before _149434,
%           not ((terminates_at(_152720,_149428,_152732),_150144 before _152732),_152732 before _149434))

% it becomes the case that
%   fluent
% when
%   event
% if 
% statement/1 or /3 
statement(Statement) --> 
    it_becomes_the_case_that_, spaces_or_newlines(_), 
        literal_([], Map1, holds(Fluent, _)), spaces_or_newlines(_), 
    when_, spaces_or_newlines(_), 
        literal_(Map1, Map2, happens(Event, T)), spaces_or_newlines(_),
    body_(Body, [map(T, '_change_time')|Map2],_), period,  
        {(Body = [] -> Statement = [if(initiates(Event, Fluent, T), true)]; 
            (Statement = [if(initiates(Event, Fluent, T), Body)]))}, !.

% it becomes not the case that
%   fluent
% when
%   event
% if  
statement(Statement) --> 
    it_becomes_not_the_case_that_, spaces_or_newlines(_), 
        literal_([], Map1, holds(Fluent, _)), spaces_or_newlines(_),
    when_, spaces_or_newlines(_),
        literal_(Map1, Map2, happens(Event, T)), spaces_or_newlines(_),
    body_(Body, [map(T, '_change_time')|Map2],_), period,  
        {(Body = [] -> Statement = [if(terminates(Event, Fluent, T), true)];  
            (Statement = [if(terminates(Event, Fluent, T), Body)] %, print_message(informational, "~w"-Statement)
            ))}, !.

% it is illegal that
%   event
% if ... 
statement(Statement) -->
    it_is_illegal_that_, spaces_or_newlines(_), 
    literal_([], Map1, happens(Event, T)), body_(Body, Map1, _), period,
    {(Body = [] -> Statement = [if(it_is_illegal(Event, T), true)]; 
      Statement = [if(it_is_illegal(Event, T), Body)])},!. 

% a fact or a rule
statement(Statement) --> currentLine(L), 
    literal_([], Map1, Head), body_(Body, Map1, _), period,  
    {(Body = [] -> Statement = [if(L, Head, true)]; Statement = [if(L, Head, Body)])}. 

% error
statement(_, Rest, _) :- 
    asserterror('LE error found around this statement: ', Rest), fail.

list_of_facts([F|R1]) --> literal_([], _,F), rest_list_of_facts(R1).

rest_list_of_facts(L1) --> comma, spaces_or_newlines(_), list_of_facts(L1).
rest_list_of_facts([]) --> [].

% assumptions_/3 or /5
assumptions_([A|R]) --> 
        spaces_or_newlines(_),  rule_([], _, A), !, assumptions_(R).
assumptions_([]) --> 
        spaces_or_newlines(_), []. 

rule_(InMap, OutMap, Rule) --> 
    literal_(InMap, Map1, Head), body_(Body, Map1, OutMap), period,  
    %spaces(Ind), condition(Head, Ind, InMap, Map1), body_(Body, Map1, OutMap), period, 
    {(Body = [] -> Rule = (Head :-true); Rule = (Head :- Body))}. 

rule_(M, M, _, Rest, _) :- 
    asserterror('LE error found in an assumption, near to ', Rest), fail.

% no prolog inside LE!
%statement([Fact]) --> 
%    spaces(_), prolog_literal_(Fact, [], _), spaces_or_newlines(_), period.
% body/3 or /5
body_([], Map, Map) --> spaces_or_newlines(_).
body_(Conditions, Map1, MapN) --> 
    newline, spaces(Ind), if_, !, conditions(Ind, Map1, MapN, Conditions), spaces_or_newlines(_).
body_(Conditions, Map1, MapN) --> 
    if_, newline_or_nothing, spaces(Ind), conditions(Ind, Map1, MapN, Conditions), spaces_or_newlines(_).

newline_or_nothing --> newline.
newline_or_nothing --> []. 

% literal_/3 or /5
% literal_ reads a list of words until it finds one of these: ['\n', if, '.']
% it then tries to match those words against a template in memory (see dict/3 predicate).
% The output is then contigent to the type of literal according to the declarations. 
literal_(Map1, MapN, FinalLiteral) --> % { print_message(informational, 'at time, literal') },
    at_time(T, Map1, Map2), comma, possible_instance(PossibleTemplate),  
    {match_template(PossibleTemplate, Map2, MapN, Literal),
     (fluents(Fluents) -> true; Fluents = []),
     (events(Events) -> true; Events = []),
     (lists:member(Literal, Events) -> FinalLiteral = happens(Literal, T) 
      ; (lists:member(Literal, Fluents) -> FinalLiteral = holds(Literal, T)
        ; FinalLiteral = Literal))}, !. % by default (including builtins) they are timeless!

literal_(Map1, MapN, FinalLiteral) --> % { print_message(informational, 'literal, at time') },
    possible_instance(PossibleTemplate), comma, at_time(T, Map1, Map2),  
    {match_template(PossibleTemplate, Map2, MapN, Literal),
     (fluents(Fluents) -> true; Fluents = []),
     (events(Events) -> true; Events = []),
     (lists:member(Literal, Events) -> FinalLiteral = happens(Literal, T) 
      ; (lists:member(Literal, Fluents) -> FinalLiteral = holds(Literal, T)
        ; FinalLiteral = Literal))}, !. % by default (including builtins) they are timeless!

literal_(Map1, MapN, FinalLiteral) -->  
    possible_instance(PossibleTemplate), %{ print_message(informational, "~w"-[PossibleTemplate]) },
    {match_template(PossibleTemplate, Map1, MapN, Literal),
     (fluents(Fluents) -> true; Fluents = []),
     (events(Events) -> true; Events = []),
     (consult_map(Time, '_change_time', Map1, _MapF) -> T=Time; true), 
     (lists:member(Literal, Events) -> FinalLiteral = happens(Literal, T) 
      ; (lists:member(Literal, Fluents) -> FinalLiteral = holds(Literal, T)
        ; (FinalLiteral = Literal)))
      %print_message(informational, "~w with ~w"-[FinalLiteral, MapF])
     }, !. % by default (including builtins) they are timeless!

% rewritten to use in swish. Fixed! It was a name clash. Apparently "literal" is used somewhere else
%literal_(Map1, MapN, Literal, In, Out) :-  print_message(informational, '  inside a literal'),
%        possible_instance(PossibleTemplate, In, Out), print_message(informational, PossibleTemplate),
%        match_template(PossibleTemplate, Map1, MapN, Literal).
% error clause
literal_(M, M, _, Rest, _) :- 
    asserterror('LE error found in a literal ', Rest), fail.

% conditions/4 or /6
conditions(Ind0, Map1, MapN, Conds) --> 
    list_of_conds_with_ind(Ind0, Map1, MapN, Errors, ListConds),
    {Errors=[] -> ri(Conds, ListConds); (assert_error_os(Errors), fail)}. % preempty validation of errors  
conditions(_, Map, Map, _, Rest, _) :-
    asserterror('LE indentation error ', Rest), fail. 

% list_of_conds_with_ind/5
% list_of_conds_with_ind(+InitialInd, +InMap, -OutMap, -Errors, -ListOfConds)
list_of_conds_with_ind(Ind0, Map1, MapN, [], [Cond|Conditions]) -->
    condition(Cond, Ind0, Map1, Map2),
    more_conds(Ind0, Ind0,_, Map2, MapN, Conditions).
list_of_conds_with_ind(_, M, M, [error('Error in condition at', LineNumber, Tokens)], [], Rest, _) :-
    once( nth1(N,Rest,newline(NextLine)) ), LineNumber is NextLine-2,
    RelevantN is N-1,
    length(Relevant,RelevantN), append(Relevant,_,Rest),
    findall(Token, (member(T,Relevant), (T=newline(_) -> Token='\n' ; Token=T)), Tokens). 

more_conds(Ind0, _, Ind3, Map1, MapN, [ind(Ind2), Op, Cond2|RestMapped]) --> 
    newline, spaces(Ind2), {Ind0 =< Ind2}, % if the new indentation is deeper, it goes on as before. 
    operator(Op), condition(Cond2, Ind2, Map1, Map2),
    %{print_message(informational, "~w"-[Conditions])}, !,
    more_conds(Ind0, Ind2, Ind3, Map2, MapN, RestMapped). 
more_conds(_, Ind, Ind, Map, Map, [], L, L).  

% three conditions look ahead
%more_conds(Ind0, Ind1, Ind4, Map1, MapN, C1, RestMapped, In1, Out) :-
%     newline(In1, In2), spaces(Ind2, In2, In3), Ind0=<Ind2, operator(Op1, In3, In4), condition(C2, Ind1, Map1, Map2, In4, In5), 
%     newline(In5, In6), spaces(Ind3, In6, In7), Ind0=<Ind3, operator(Op2, In7, In8), condition(C3, Ind2, Map2, Map3, In8, In9), 
%     adjust_op(Ind2, Ind3, C1, Op1, C2, Op2, C3, Conditions), !, 
%     more_conds(Ind0, Ind3, Ind4, Map3, MapN, Conditions, RestMapped, In9, Out). 
% % more_conds(PreviosInd, CurrentInd, MapIn, MapOut, InCond, OutConds)
% more_conds(Ind0, Ind1, Ind, Map1, MapN, Cond, Conditions) --> 
%     newline, spaces(Ind), {Ind0 =< Ind}, % if the new indentation is deeper, it goes on as before. 
%     operator(Op), condition(Cond2, Ind, Map1, MapN),
%     {add_cond(Op, Ind1, Ind, Cond, Cond2, Conditions)},  
%     {print_message(informational, "~w"-[Conditions])}, !.
% more_conds(Ind0, Ind1, Ind3, Map1, MapN, Cond, RestMapped) --> 
%     newline, spaces(Ind2), {Ind0 =< Ind2}, % if the new indentation is deeper, it goes on as before. 
%     operator(Op), condition(Cond2, Ind2, Map1, Map2),
%     {add_cond(Op, Ind1, Ind2, Cond, Cond2, Conditions)},  !, 
%     %{print_message(informational, "~w"-[Conditions])}, !,
%     more_conds(Ind0, Ind2, Ind3, Map2, MapN, Conditions, RestMapped). 
% more_conds(_, Ind, Ind, Map, Map, Cond, Cond, Rest, Rest).  
 
% this naive definition of term is problematic
% term_/4 or /6
term_(StopWords, Term, Map1, MapN) --> 
    (variable(StopWords, Term, Map1, MapN), !); (constant(StopWords, Term, Map1, MapN), !); (list_(Term, Map1, MapN), !). %; (compound_(Term, Map1, MapN), !).

% list_/3 or /5
list_(List, Map1, MapN) --> 
    spaces(_), bracket_open_, !, extract_list([']'], List, Map1, MapN), bracket_close.   

compound_(V1/V2, Map1, MapN) --> 
    term_(['/'], V1, Map1, Map2), ['/'], term_([], V2, Map2, MapN). 

% event observations
%condition(happens(Event), _, Map1, MapN) -->
%    observe_,  literal_(Map1, MapN, Event), !.

% condition/4 or /6
% this produces a Taxlog condition with the form: 
% setof(Owner/Share, is_ultimately_owned_by(Asset,Owner,Share) on Before, SetOfPreviousOwners)
% from a set of word such as: 
%     and a record of previous owners is a set of [an owner, a share] 
%           where the asset is ultimately owned by the share with the owner at the previous time
condition(FinalExpression, _, Map1, MapN) --> 
    variable([is], Set, Map1, Map2), is_a_set_of_, term_([], Term, Map2, Map3), !, % moved where to the following line
    newline, spaces(Ind2), where_, conditions(Ind2, Map3, Map4, Goals),
    modifiers(setof(Term,Goals,Set), Map4, MapN, FinalExpression).

% for every a party is a party in the event, it is the case that:
condition(FinalExpression, _, Map1, MapN) -->  
    for_all_cases_in_which_, newline, !, 
    spaces(Ind2), conditions(Ind2, Map1, Map2, Conds), spaces_or_newlines(_), 
    it_is_the_case_that_, newline, 
    spaces(Ind3), conditions(Ind3, Map2, Map3, Goals),
    modifiers(forall(Conds,Goals), Map3, MapN, FinalExpression).

% the Value is the sum of each Asset Net such that
condition(FinalExpression, _, Map1, MapN) --> 
    variable([is], Value, Map1, Map2), is_the_sum_of_each_, extract_variable([such], [], NameWords, [], _), such_that_, !, 
    { name_predicate(NameWords, Name), update_map(Each, Name, Map2, Map3) }, newline, 
    spaces(Ind), conditions(Ind, Map3, Map4, Conds), 
    modifiers(aggregate_all(sum(Each),Conds,Value), Map4, MapN, FinalExpression).
    
% it is not the case that 
%condition((pengine_self(M), not(M:Conds)), _, Map1, MapN) --> 
%condition((true, not(Conds)), _, Map1, MapN) -->
condition(not(Conds), _, Map1, MapN) --> 
%condition(not(Conds), _, Map1, MapN) --> 
    spaces(_), not_, newline,  % forget other choices. We know it is a not case
    spaces(Ind), conditions(Ind, Map1, MapN, Conds), !.

condition(Cond, _, Map1, MapN) -->  
    literal_(Map1, MapN, Cond), !. 

%condition(assert(Prolog), _, Map1, MapN) -->
%    this_information_, !, prolog_literal_(Prolog, Map1, MapN), has_been_recorded_. 

% condition(-Cond, ?Ind, +InMap, -OutMap)
% builtins have been included as predefined templates in the predef_dict
%condition(InfixBuiltIn, _, Map1, MapN) --> 
%    term_(Term, Map1, Map2), spaces_or_newlines(_), builtin_(BuiltIn), 
%    spaces_or_newlines(_), expression_(Expression, Map2, MapN), !, {InfixBuiltIn =.. [BuiltIn, Term, Expression]}. 

% error clause
condition(_, _Ind, Map, Map, Rest, _) :- 
        asserterror('LE error found at a condition ', Rest), fail.

% modifiers add reifying predicates to an expression. 
% modifiers(+MainExpression, +MapIn, -MapOut, -FinalExpression)
modifiers(MainExpression, Map1, MapN, on(MainExpression, Var) ) -->
    newline, spaces(_), at_, variable([], Var, Map1, MapN). % newline before a reifying expression
modifiers(MainExpression, Map, Map, MainExpression) --> [].  

% variable/4 or /6
variable(StopWords, Var, Map1, MapN) --> 
    spaces(_), indef_determiner, extract_variable(StopWords, [], NameWords, [], _), % <-- CUT!
    {  NameWords\=[], name_predicate(NameWords, Name), update_map(Var, Name, Map1, MapN) }. 
variable(StopWords, Var, Map1, MapN) --> 
    spaces(_), def_determiner, extract_variable(StopWords, [], NameWords, [], _), % <-- CUT!
    {  NameWords\=[], name_predicate(NameWords, Name), consult_map(Var, Name, Map1, MapN) }. 
% allowing for symbolic variables: 
variable(StopWords, Var, Map1, MapN) --> 
    spaces(_), extract_variable(StopWords, [], NameWords, [], _),
    {  NameWords\=[], name_predicate(NameWords, Name), consult_map(Var, Name, Map1, MapN) }. 

% constant/4 or /6
constant(StopWords, Constant, Map, Map) -->
    extract_constant(StopWords, NameWords), { NameWords\=[], name_predicate(NameWords, Constant) }. 

% deprecated
prolog_literal_(Prolog, Map1, MapN) -->
    predicate_name_(Predicate), parentesis_open_, extract_list([], Arguments, Map1, MapN), parentesis_close_,
    {Prolog =.. [Predicate|Arguments]}.

predicate_name_(Module:Predicate) --> 
    [Module], colon_, extract_constant([], NameWords), { name_predicate(NameWords, Predicate) }, !.
predicate_name_(Predicate) --> extract_constant([], NameWords), { name_predicate(NameWords, Predicate) }.

at_time(T, Map1, MapN) --> spaces_or_newlines(_), at_, expression_(T, Map1, MapN), spaces_or_newlines(_).

spaces(N) --> [' '], !, spaces(M), {N is M + 1}.
% todo: reach out for codemirror's configuration https://codemirror.net/doc/manual.html for tabSize
spaces(N) --> ['\t'], !, spaces(M), {N is M + 4}. % counting tab as four spaces (default in codemirror)
spaces(0) --> []. 

spaces_or_newlines(N) --> [' '], !, spaces_or_newlines(M), {N is M + 1}.
spaces_or_newlines(N) --> ['\t'], !, spaces_or_newlines(M), {N is M + 4}. % counting tab as four spaces. See above
spaces_or_newlines(N) --> newline, !, spaces_or_newlines(M), {N is M + 1}. % counting \r as one space
spaces_or_newlines(0) --> [].

newline --> [newline(_Next)].

one_or_many_newlines --> newline, spaces(_), one_or_many_newlines, !. 
one_or_many_newlines --> [].

if_ --> [if], spaces_or_newlines(_).  % so that if can be written many lines away from the rest
if_ --> [se], spaces_or_newlines(_).  % italian
if_ --> [si], spaces_or_newlines(_).  % french and spanish

period --> ['.'].
comma --> [','].
colon_ --> [':'], spaces(_). 

comma_or_period --> period, !.
comma_or_period --> comma. 

and_ --> [and].
and_ --> [e].  % italian
and_ --> [et]. % french
and_ --> [y].  % spanish

or_ --> [or].
or_ --> [o].  % italian and spanish
or_ --> [ou]. % french

not_ --> [it], spaces(_), [is], spaces(_), [not], spaces(_), [the], spaces(_), [case], spaces(_), [that], spaces(_). 
not_ --> [non], spaces(_), [è], spaces(_), [provato], spaces(_), [che], spaces(_). % italian
not_ --> [ce], spaces(_), [n],[A],[est], spaces(_), [pas], spaces(_), [le], spaces(_), [cas], spaces(_), [que], spaces(_), {atom_string(A, "'")}. % french
not_ --> [no], spaces(_), [es], spaces(_), [el], spaces(_), [caso], spaces(_), [que], spaces(_).  % spanish

is_the_sum_of_each_ --> [is], spaces(_), [the], spaces(_), [sum], spaces(_), [of], spaces(_), [each], spaces(_) .
is_the_sum_of_each_ --> [è], spaces(_), [la], spaces(_), [somma], spaces(_), [di], spaces(_), [ogni], spaces(_). % italian
is_the_sum_of_each_ --> [es], spaces(_), [la], spaces(_), [suma], spaces(_), [de], spaces(_), [cada], spaces(_). % spanish
is_the_sum_of_each_ --> [est], spaces(_), [la], spaces(_), [somme], spaces(_), [de], spaces(_), [chaque], spaces(_). % french

such_that_ --> [such], spaces(_), [that], spaces(_). 
such_that_ --> [tale], spaces(_), [che], spaces(_). % italian
such_that_ --> [tel], spaces(_), [que], spaces(_).  % french
such_that_ --> [tal], spaces(_), [que], spaces(_).  % spanish

at_ --> [at], spaces(_). 
at_ --> [a], spaces(_). % italian 

minus_ --> ['-'], spaces(_).

plus_ --> ['+'], spaces(_).

divide_ --> ['/'], spaces(_).

times_ --> ['*'], spaces(_).

bracket_open_ --> [A], spaces(_), {atom_string(A, "[")}.
bracket_close --> [A], spaces(_), {atom_string(A, "]")}. 

parentesis_open_ --> ['('], spaces(_).
parentesis_close_ --> [A], spaces(_), {atom_string(A, ")")}. 

this_information_ --> [this], spaces(_), [information], spaces(_).

has_been_recorded_ --> [has], spaces(_), [been], spaces(_), [recorded], spaces(_).

for_all_cases_in_which_ --> spaces_or_newlines(_), [for], spaces(_), [all], spaces(_), [cases], spaces(_), [in], spaces(_), [which], spaces(_).
for_all_cases_in_which_ --> spaces_or_newlines(_), [pour], spaces(_), [tous], spaces(_), [les], spaces(_), [cas], spaces(_), [o],[ù], spaces(_).  % french 
for_all_cases_in_which_ --> spaces_or_newlines(_), [per], spaces(_), [tutti], spaces(_), [i], spaces(_), [casi], spaces(_), [in], spaces(_), [cui], spaces(_).  % italian 

it_is_the_case_that_ --> [it], spaces(_), [is], spaces(_), [the], spaces(_), [case], spaces(_), [that], spaces(_).
it_is_the_case_that_ --> [es], spaces(_), [el], spaces(_), [caso], spaces(_), [que], spaces(_).  % spanish
it_is_the_case_that_ --> [c], [A], [est], spaces(_), [le], spaces(_), [cas], spaces(_), [que], spaces(_), {atom_string(A, "'")}. % french
it_is_the_case_that_ --> [è], spaces(_), [provato], spaces(_), [che], spaces(_). % italian

is_a_set_of_ --> [is], spaces(_), [a], spaces(_), [set], spaces(_), [of], spaces(_). 
is_a_set_of_ --> [es], spaces(_), [un],  spaces(_), [conjunto],  spaces(_), [de], spaces(_). % spanish
is_a_set_of_ --> [est], spaces(_), [un],  spaces(_), [ensemble],  spaces(_), [de],  spaces(_). % french
is_a_set_of_ --> [est], spaces(_), [un],  spaces(_), [ensemble],  spaces(_), [de],  spaces(_). % italian

where_ --> [where], spaces(_). 
where_ --> [en], spaces(_), [donde], spaces(_). % spanish
where_ --> ['où'], spaces(_). % french  
where_ --> [dove], spaces(_). % italian
where_ --> [quando], spaces(_). % italian

scenario_ -->  spaces_or_newlines(_), ['Scenario'], !, spaces(_).
scenario_ -->  spaces_or_newlines(_), [scenario], spaces(_). % english and italian
scenario_ -->  spaces_or_newlines(_), [scénario], spaces(_). % french
scenario_ -->  spaces_or_newlines(_), [escenario], spaces(_). % spanish

is_colon_ -->  [is], spaces(_), [':'], spaces(_).
is_colon_ -->  [es], spaces(_), [':'], spaces(_).  % spanish
is_colon_ -->  [est], spaces(_), [':'], spaces(_). % french
is_colon_ -->  [è], spaces(_), [':'], spaces(_). % italian

query_ --> spaces_or_newlines(_), ['Query'], !, spaces(_).
query_ --> spaces_or_newlines(_), [query], spaces(_).
query_ --> spaces_or_newlines(_), [question], spaces(_). % french
query_ --> spaces_or_newlines(_), [la], spaces(_), [pregunta], spaces(_). % spanish
query_ --> spaces_or_newlines(_), [domanda], spaces(_). % italian

for_which_ --> [for], spaces(_), [which], spaces(_). 
for_which_ --> [para], spaces(_), [el], spaces(_), [cual], spaces(_). % spanish singular
for_which_ --> [pour], spaces(_), [qui], spaces(_). % french
for_which_ --> [per], spaces(_), [cui], spaces(_). % italian

query_header(Ind, Map) --> spaces(Ind), for_which_, list_of_vars([], Map), colon_, spaces_or_newlines(_).
query_header(0, []) --> []. 

list_of_vars(Map1, MapN) --> 
    extract_variable([',', and, el, et, y, ':'], [], NameWords, [], _), 
    { name_predicate(NameWords, Name), update_map(_Var, Name, Map1, Map2) },
    rest_of_list_of_vars(Map2, MapN).

rest_of_list_of_vars(Map1, MapN) --> and_or_comma_, list_of_vars(Map1, MapN).
rest_of_list_of_vars(Map, Map) --> []. 

and_or_comma_ --> [','], spaces(_). 
and_or_comma_ --> and_, spaces(_).

it_becomes_the_case_that_ --> 
    it_, [becomes], spaces(_), [the], spaces(_), [case], spaces(_), [that], spaces(_).

it_becomes_not_the_case_that_ -->
    it_, [becomes], spaces(_), [not], spaces(_), [the], spaces(_), [case], spaces(_), [that], spaces(_).
it_becomes_not_the_case_that_ -->
    it_, [becomes], spaces(_), [no], spaces(_), [longer], spaces(_), [the], spaces(_), [case], spaces(_), [that], spaces(_).

when_ --> [when], spaces(_).

it_ --> [it], spaces(_), !.
it_ --> ['It'], spaces(_). 

observe_ --> [observe], spaces(_). 

it_is_illegal_that_  -->
    it_, [is], spaces(_), [illegal], spaces(_), [that], spaces(_).

/* --------------------------------------------------- Supporting code */
% indentation code
% ri/2 ri(-Conditions, +IndentedForm). 

ri(P, L) :- rinden(Q, L), c2p(Q, P).  

% rinden/2 produces the conditions from the list with the indented form. 
rinden(Q, List) :- rind(_, _, Q, List).  

rind(L, I, Q, List) :- rind_and(L, I, Q, List); rind_or(L, I, Q, List). 

rind_and(100, [], true, []). 
rind_and(100, [], Cond, [Cond]) :- simple(Cond). 
rind_and(T, [T|RestT], and(First,Rest), Final) :-
	combine(NewF, [ind(T), and|RestC], Final),
	rind(T1, Tr1, First, NewF),
	T1>T, 
	rind(Tn, Tr, Rest, RestC),
	append(Tr1, Tr, RestT), 
	right_order_and(Rest, Tn, T). 

rind_or(100, [], false, []). 
rind_or(100, [], Cond, [Cond]) :- simple(Cond).
rind_or(T, [T|RestT], or(First,Rest), Final) :-
	combine(NewF, [ind(T), or|RestC], Final), 
	rind(T1, Tr1, First, NewF),
	T1>T, 
	rind(Tn, Tr, Rest, RestC),
	append(Tr1, Tr, RestT), 
	right_order_or(Rest, Tn, T).    
	
right_order_and(Rest, Tn, T) :- Rest=or(_,_), Tn>T. 
right_order_and(Rest, Tn, T) :- Rest=and(_,_), Tn=T.
right_order_and(Rest, _, _) :- simple(Rest).  

right_order_or(Rest, Tn, T) :- Rest=and(_,_), Tn>T. 
right_order_or(Rest, Tn, T) :- Rest=or(_,_), Tn=T.
right_order_or(Rest, _, _) :- simple(Rest).  

combine(F, S, O) :- ( F\=[], S=[ind(_), Op, V], ((Op==and_); (Op==or_)), simple(V), O=F) ; (F=[], O=S). 
combine([H|T], S, [H|NT]) :- combine(T, S, NT). 

simple(Cond) :- Cond\=and(_,_), Cond\=or(_,_), Cond\=true, Cond\=false.  

c2p(true, true).
c2p(false, false). 
c2p(C, C) :- simple(C). 
c2p(and(A, RestA), (AA, RestAA)) :- 
	c2p(A, AA), 
	c2p(RestA, RestAA). 
c2p(or(A, RestA), (AA; RestAA)) :- 
	c2p(A, AA), 
	c2p(RestA, RestAA). 

/* --------------------------------------------------- More Supporting code */
clean_comments([], []) :- !.
clean_comments(['%'|Rest], New) :- % like in prolog comments start with %
    jump_comment(Rest, Next), 
    clean_comments(Next, New). 
clean_comments([Code|Rest], [Code|New]) :-
    clean_comments(Rest, New).

jump_comment([], []).
jump_comment([newline(N)|Rest], [newline(N)|Rest]). % leaving the end of line in place
jump_comment([_|R1], R2) :-
    jump_comment(R1, R2). 

% template_decl/4
% cuts added to improve efficiency
template_decl([], [newline(_)|RestIn], [newline(_)|RestIn]) :- 
    asserterror('LE error: misplaced new line found in a template declaration ', RestIn), !, 
    fail. % cntrl \n should be rejected as part of a template
template_decl(RestW, [' '|RestIn], Out) :- !, % skip spaces in template
    template_decl(RestW, RestIn, Out).
template_decl(RestW, ['\t'|RestIn], Out) :- !, % skip cntrl \t in template
    template_decl(RestW, RestIn, Out).
% excluding ends of lines from templates
%template_decl(RestW, [newline(_)|RestIn], Out) :- !, % skip cntrl \n in template
%    template_decl(RestW, RestIn, Out).
template_decl([Word|RestW], [Word|RestIn], Out) :-
    not(lists:member(Word,['.', ','])),   % only . and , as boundaries. Beware!
    template_decl(RestW, RestIn, Out), !.
template_decl([], [Word|Rest], [Word|Rest]) :-
    lists:member(Word,['.', ',']), !.
template_decl(_, Rest, _) :- 
    asserterror('LE error found in a template declaration ', Rest), fail.

% build_template/5
build_template(RawTemplate, Predicate, Arguments, TypesAndNames, Template) :-
    build_template_elements(RawTemplate, [], Arguments, TypesAndNames, OtherWords, Template),
    name_predicate(OtherWords, Predicate).

% build_template_elements(+Input, +Previous, -Args, -TypesNames, -OtherWords, -Template)
build_template_elements([], _, [], [], [], []) :- !. 
% a variable signalled by a *
build_template_elements(['*', Word|RestOfWords], _Previous, [Var|RestVars], [Name-Type|RestTypes], Others, [Var|RestTemplate]) :-
    has_pairing_asteriks([Word|RestOfWords]), 
    %(ind_det(Word); ind_det_C(Word)), % Previous \= [is|_], % removing this requirement when * is used
    phrase(determiner, [Word|RestOfWords], RRestOfWords), % allows the for variables in templates declarations only
    extract_variable_template(['*'], [], NameWords, [], TypeWords, RRestOfWords, ['*'|NextWords]), !, % <-- it must end with * too
    name_predicate(NameWords, Name),
    name_predicate(TypeWords, Type), 
    build_template_elements(NextWords, [], RestVars, RestTypes, Others, RestTemplate). 
build_template_elements(['*', Word|RestOfWords], _Previous,_, _, _, _) :-
    not(has_pairing_asteriks([Word|RestOfWords])), !, fail. % produce an error report if asterisks are not paired
% a variable not signalled by a *  % for backward compatibility  \\ DEPRECATED
%build_template_elements([Word|RestOfWords], Previous, [Var|RestVars], [Name-Type|RestTypes], Others, [Var|RestTemplate]) :-
%    (ind_det(Word); ind_det_C(Word)), Previous \= [is|_], 
%    extract_variable(['*'], Var, [], NameWords, TypeWords, RestOfWords, NextWords), !, % <-- CUT!
%    name_predicate(NameWords, Name), 
%    name_predicate(TypeWords, Type), 
%    build_template_elements(NextWords, [], RestVars, RestTypes, Others, RestTemplate).
build_template_elements([Word|RestOfWords], Previous, RestVars, RestTypes,  [Word|Others], [Word|RestTemplate]) :-
    build_template_elements(RestOfWords, [Word|Previous], RestVars, RestTypes, Others, RestTemplate).

has_pairing_asteriks(RestOfTemplate) :-
    findall('*',member('*', RestOfTemplate), Asteriks), length(Asteriks, N), 1 is mod(N, 2).

name_predicate(Words, Predicate) :-
    concat_atom(Words, '_', Predicate). 

% name_as_atom/2
name_as_atom([Number], Number) :-
    number(Number), !. 
name_as_atom([Atom], Number) :- 
    atom_number(Atom, Number), !. 
name_as_atom(Words, Name) :-
    numbervars(Words, 1, _, [functor_name('unknown')]),
    replace_vars(Words, Atoms), 
    list_words_to_codes(Atoms, Codes),
    replace_ast_a(Codes, CCodes), 
    atom_codes(Name, CCodes).  

words_to_atom(Words, Name) :- %trace, 
    numbervars(Words, 0, _, [singletons(true)]),
    list_words_to_codes(Words, Codes),
    atom_codes(Name, Codes). 

replace_ast_a([], []) :- !. 
replace_ast_a([42,32,97|Rest], [42,97|Out]) :- !, 
    replace_final_ast(Rest, Out). 
replace_ast_a([C|Rest], [C|Out]) :-
    replace_ast_a(Rest, Out).

replace_final_ast([], []) :- !. 
replace_final_ast([32,42|Rest], [42|Out]) :- !, 
    replace_ast_a(Rest, Out).
replace_final_ast([C|Rest], [C|Out]) :-
    replace_final_ast(Rest, Out).

% maps a list of words to a list of corresponding codes
% adding an space between words-codes (32). 
% list_word_to_codes/2
list_words_to_codes([], []).
list_words_to_codes([Word|RestW], Out) :-
    atom_codes(Word, Codes),
    remove_quotes(Codes, CleanCodes), 
    list_words_to_codes(RestW, Next),
    (Next=[]-> Out=CleanCodes; append(CleanCodes, [32|Next], Out)), !. 

remove_quotes([], []) :-!.
remove_quotes([39|RestI], RestC) :- remove_quotes(RestI, RestC), !.
% quick fix to remove parentesis and numbers too. 
remove_quotes([40, _, 41|RestI], RestC) :- remove_quotes(RestI, RestC), !.
%remove_quotes([41|RestI], RestC) :- remove_quotes(RestI, RestC), !.
remove_quotes([C|RestI], [C|RestC]) :- remove_quotes(RestI, RestC). 

replace_vars([],[]) :- !.
replace_vars([A|RI], [A|RO]) :- atom(A), replace_vars(RI,RO), !.
replace_vars([W|RI], [A|RO]) :- term_to_atom(W, A), replace_vars(RI,RO).   

add_cond(and, Ind1, Ind2, Previous, C4, (C; (C3, C4))) :-
    last_cond(or, Previous, C, C3), % (C; C3)
    Ind1 < Ind2, !. 
add_cond(and, Ind1, Ind2, Previous, C4, ((C; C3), C4)) :-
    last_cond(or, Previous, C, C3), % (C; C3)
    Ind1 > Ind2, !.     
add_cond(and,I, I, (C, C3), C4, (C, (C3, C4))) :- !. 
add_cond(and,_, _, Cond, RestC, (Cond, RestC)) :- !. 
add_cond(or, Ind1, Ind2, Previous, C4, (C, (C3; C4))) :- 
    last_cond(and, Previous, C, C3),  % (C, C3)
    Ind1 < Ind2, !. 
add_cond(or, Ind1, Ind2, Previous, C4, ((C, C3); C4)) :- 
    last_cond(and, Previous, C, C3), % (C, C3)
    Ind1 > Ind2, !. 
add_cond(or, I, I, (C; C3), C4, (C; (C3; C4))) :- !. 
add_cond(or, _, _, Cond, RestC, (Cond; RestC)).

last_cond(or, (A;B), A, B) :- B\=(_;_), !.
last_cond(or, (C;D), (C;R), Last) :- last_cond(or, D, R, Last).

last_cond(and, (A,B), A, B) :- B\=(_,_), !.
last_cond(and, (C,D), (C,R), Last) :- last_cond(and, D, R, Last).

% adjust_op(Ind1, Ind2, PreviousCond, Op1, Cond2, Op2, Rest, RestMapped, Conditions)
% from and to and
adjust_op(Ind1, Ind2, C1, and, C2, and, C3, ((C1, C2), C3) ) :- 
    Ind1 =< Ind2, !.
adjust_op(Ind1, Ind2, C1, and, C2, and, C3, ((C1, C2), C3) ) :- 
    Ind1 > Ind2, !.
% from or to ord
adjust_op(Ind1, Ind2, C1, or, C2, or, C3, ((C1; C2); C3) ) :- 
    Ind1 =< Ind2, !.
adjust_op(Ind1, Ind2, C1, or, C2, or, C3, ((C1; C2); C3) ) :- 
    Ind1 > Ind2, !.
% from and to deeper or
adjust_op(Ind1, Ind2, C1, and, C2, or, C3, (C1, (C2; C3)) ) :- 
    Ind1 < Ind2, !.
% from deeper or to and
adjust_op(Ind1, Ind2, C1, or, C2, and, C3, ((C1; C2), C3) ) :- 
    Ind1 > Ind2, !.
% from or to deeper and
adjust_op(Ind1, Ind2, C1, or, C2, and, C3, (C1; (C2, C3)) ) :- 
    Ind1 < Ind2, !.
% from deeper and to or
adjust_op(Ind1, Ind2, C1, and, C2, or, C3, ((C1, C2); C3) ) :- 
    Ind1 > Ind2.

operator(and, In, Out) :- and_(In, Out).
operator(or, In, Out) :- or_(In, Out).

% possible_instance/3
% cuts added to improve efficiency
% skipping a list
possible_instance([], [], []) :- !. 
possible_instance(Final, ['['|RestIn], Out) :- !, 
    possible_instance_for_lists(List, RestIn, [']'|Next]),  
    possible_instance(RestW, Next, Out),
    append(['['|List], [']'|RestW], Final).  
possible_instance(RestW, [' '|RestIn], Out) :- !, % skip spaces in template
    possible_instance(RestW, RestIn, Out).
possible_instance(RestW, ['\t'|RestIn], Out) :- !, % skip tabs in template
    possible_instance(RestW, RestIn, Out).
possible_instance([that|Instance], In, Out) :- % to allow "that" instances to spread over more than one line
    phrase(spaces_or_newlines(_), In, [that|Rest]),
    phrase(spaces_or_newlines(_), Rest, Next), !, 
    possible_instance(Instance, Next, Out).
possible_instance([Word|RestW], [Word|RestIn], Out) :- 
    %not(lists:member(Word,['\n', if, and, or, '.', ','])),  !, 
    not(lists:member(Word,[newline(_), if, '.', ','])), 
    % leaving the comma in as well (for lists and sets we will have to modify this)
    possible_instance(RestW, RestIn, Out).
possible_instance([], [Word|Rest], [Word|Rest]) :- 
    lists:member(Word,[newline(_), if, '.', ',']). % leaving or/and out of this

% using [ and ] for list and set only to avoid clashes for commas
%possible_instance_for_lists([], [], []) :- !.
possible_instance_for_lists([], [']'|Out], [']'|Out]) :- !. 
possible_instance_for_lists(RestW, [' '|RestIn], Out) :- !, % skip spaces in template
    possible_instance_for_lists(RestW, RestIn, Out).
possible_instance_for_lists(RestW, ['\t'|RestIn], Out) :- !, % skip tabs in template
    possible_instance_for_lists(RestW, RestIn, Out).
possible_instance_for_lists([Word|RestW], [Word|RestIn], Out) :- 
    %not(lists:member(Word,['\n', if, and, or, '.', ','])),  !, 
    possible_instance_for_lists(RestW, RestIn, Out).
%possible_instance_for_lists([], [Word|Rest], [Word|Rest]) :- 
%    lists:member(Word,[',', newline(_), if, '.']). % leaving or/and out of this

% match_template/4
match_template(PossibleLiteral, Map1, MapN, Literal) :-
    %print_message(informational,'Possible Meta Literal ~w'-[PossibleLiteral]),
    meta_dictionary(Predicate, _, MetaCandidate),
    meta_match(MetaCandidate, PossibleLiteral, Map1, MapN, MetaTemplate), !, 
    meta_dictionary(Predicate, _, MetaTemplate),
    Literal =.. Predicate. 

match_template(PossibleLiteral, Map1, MapN, Literal) :- 
    %print_message(informational,'Possible Literal ~w'-[PossibleLiteral]),
    dictionary(Predicate, _, Candidate),
    match(Candidate, PossibleLiteral, Map1, MapN, Template), !, 
    dictionary(Predicate, _, Template), 
    Literal =.. Predicate.
    %print_message(informational,'Match!! with ~w'-[Literal]).% !. 

% meta_match/5
% meta_match(+CandidateTemplate, +PossibleLiteral, +MapIn, -MapOut, -SelectedTemplate)
meta_match([], [], Map, Map, []) :- !.
meta_match([Word|_LastElement], [Word|PossibleLiteral], Map1, MapN, [Word,Literal]) :- % asuming Element is last in template!
    Word = that, % that is a reserved word "inside" templates! -> <meta level> that <object level> 
    (meta_dictionary(Predicate, _, Candidate); dictionary(Predicate, _, Candidate)), % searching for a new inner literal
    match(Candidate, PossibleLiteral, Map1, MapN, InnerTemplate),
    (meta_dictionary(Predicate, _, InnerTemplate); dictionary(Predicate, _, InnerTemplate)), 
    Literal =.. Predicate, !. 
meta_match([MetaElement|RestMetaElements], [MetaWord|RestPossibleLiteral], Map1, MapN, [MetaElement|RestSelected]) :-
    nonvar(MetaElement), MetaWord = MetaElement, !, 
    meta_match(RestMetaElements, RestPossibleLiteral, Map1, MapN, RestSelected).
%meta_match([MetaElement|RestMetaElements], PossibleLiteral, Map1, MapN, [Literal|RestSelected]) :-
%    var(MetaElement), stop_words(RestMetaElements, StopWords), 
%    extract_literal(StopWords, LiteralWords, PossibleLiteral, NextWords),
%    meta_dictionary(Predicate, _, Candidate),
%    match(Candidate, LiteralWords, Map1, Map2, Template),  %only two meta levels! % does not work. 
%    meta_dictionary(Predicate, _, Template), 
%    Literal =.. Predicate, !, 
%    meta_match(RestMetaElements, NextWords, Map2, MapN, RestSelected).  
meta_match([MetaElement|RestMetaElements], PossibleLiteral, Map1, MapN, [Literal|RestSelected]) :-
    var(MetaElement), stop_words(RestMetaElements, StopWords), 
    extract_literal(StopWords, LiteralWords, PossibleLiteral, NextWords),
    dictionary(Predicate, _, Candidate), % this assumes that the "contained" literal is an object level literal. 
    match(Candidate, LiteralWords, Map1, Map2, Template), 
    dictionary(Predicate, _, Template), 
    Literal =.. Predicate, !, 
    meta_match(RestMetaElements, NextWords, Map2, MapN, RestSelected).  
% it could also be an object level matching of other kind
meta_match([Element|RestElements], [Det|PossibleLiteral], Map1, MapN, [Var|RestSelected]) :-
    var(Element), 
    phrase(indef_determiner, [Det|PossibleLiteral], RPossibleLiteral), stop_words(RestElements, StopWords), 
    extract_variable(StopWords, [], NameWords, [], _, RPossibleLiteral, NextWords),  NameWords \= [], % <- leave that _ unbound!
    name_predicate(NameWords, Name), 
    update_map(Var, Name, Map1, Map2), !,  % <-- CUT!  
    meta_match(RestElements, NextWords, Map2, MapN, RestSelected). 
meta_match([Element|RestElements], [Det|PossibleLiteral], Map1, MapN, [Var|RestSelected]) :-
    var(Element), 
    phrase(def_determiner, [Det|PossibleLiteral], RPossibleLiteral), stop_words(RestElements, StopWords), 
    extract_variable(StopWords, [], NameWords, [], _, RPossibleLiteral, NextWords),  NameWords \= [], % <- leave that _ unbound!
    name_predicate(NameWords, Name), 
    consult_map(Var, Name, Map1, Map2), !,  % <-- CUT!  
    meta_match(RestElements, NextWords, Map2, MapN, RestSelected). 
% handling symbolic variables (as long as they have been previously defined and included in the map!) 
meta_match([Element|RestElements], PossibleLiteral, Map1, MapN, [Var|RestSelected]) :-
    var(Element), stop_words(RestElements, StopWords), 
    extract_variable(StopWords, [], NameWords, [], _, PossibleLiteral, NextWords),  NameWords \= [], % <- leave that _ unbound!
    name_predicate(NameWords, Name), 
    consult_map(Var, Name, Map1, Map2), !, % <-- CUT!  % if the variables has been previously registered
    meta_match(RestElements, NextWords, Map2, MapN, RestSelected).
meta_match([Element|RestElements], ['['|PossibleLiteral], Map1, MapN, [List|RestSelected]) :-
    var(Element), stop_words(RestElements, StopWords),
    extract_list([']'|StopWords], List, Map1, Map2, PossibleLiteral, [']'|NextWords]), !, % matching brackets verified
    meta_match(RestElements, NextWords, Map2, MapN, RestSelected).
% enabling expressions and constants
meta_match([Element|RestElements], [Word|PossibleLiteral], Map1, MapN, [Expression|RestSelected]) :-
    var(Element), stop_words(RestElements, StopWords),
    extract_expression([','|StopWords], NameWords, [Word|PossibleLiteral], NextWords), NameWords \= [],
    % this expression cannot add variables 
    ( phrase(expression_(Expression, Map1, Map1), NameWords) -> true ; ( name_predicate(NameWords, Expression) ) ),
    %print_message(informational, 'found a constant or an expression '), print_message(informational, Expression),
    meta_match(RestElements, NextWords, Map1, MapN, RestSelected). 

% match/5
% match(+CandidateTemplate, +PossibleLiteral, +MapIn, -MapOut, -SelectedTemplate)
match([], [], Map, Map, []) :- !.  % success! It succeds iff PossibleLiteral is totally consumed
% meta level access: that New Literal
match([Word|_LastElement], [Word|PossibleLiteral], Map1, MapN, [Word,Literal]) :- % asuming Element is last in template!
    Word = that, % that is a reserved word "inside" templates! -> <meta level> that <object level> 
    (meta_dictionary(Predicate, _, Candidate); dictionary(Predicate, _, Candidate)), % searching for a new inner literal
    match(Candidate, PossibleLiteral, Map1, MapN, InnerTemplate),
    (meta_dictionary(Predicate, _, InnerTemplate); dictionary(Predicate, _, InnerTemplate)), 
    Literal =.. Predicate, !. 
match([Element|RestElements], [Word|PossibleLiteral], Map1, MapN, [Element|RestSelected]) :-
    nonvar(Element), Word = Element, 
    match(RestElements, PossibleLiteral, Map1, MapN, RestSelected). 
match([Element|RestElements], [Det|PossibleLiteral], Map1, MapN, [Var|RestSelected]) :-
    var(Element), 
    phrase(indef_determiner,[Det|PossibleLiteral], RPossibleLiteral), stop_words(RestElements, StopWords), 
    extract_variable(StopWords, [], NameWords, [], _, RPossibleLiteral, NextWords),  NameWords \= [], % <- leave that _ unbound!
    name_predicate(NameWords, Name), 
    update_map(Var, Name, Map1, Map2), !,  % <-- CUT!  
    match(RestElements, NextWords, Map2, MapN, RestSelected). 
match([Element|RestElements], [Det|PossibleLiteral], Map1, MapN, [Var|RestSelected]) :-
    var(Element), 
    phrase(def_determiner, [Det|PossibleLiteral], RPossibleLiteral), stop_words(RestElements, StopWords), 
    extract_variable(StopWords, [], NameWords, [], _, RPossibleLiteral, NextWords),  NameWords \= [], % <- leave that _ unbound!
    name_predicate(NameWords, Name), 
    consult_map(Var, Name, Map1, Map2), !,  % <-- CUT!  
    match(RestElements, NextWords, Map2, MapN, RestSelected). 
% handling symbolic variables (as long as they have been previously defined and included in the map!) 
match([Element|RestElements], PossibleLiteral, Map1, MapN, [Var|RestSelected]) :-
    var(Element), stop_words(RestElements, StopWords), 
    extract_variable(StopWords, [], NameWords, [], _, PossibleLiteral, NextWords),  NameWords \= [], % <- leave that _ unbound!
    name_predicate(NameWords, Name), 
    consult_map(Var, Name, Map1, Map2), !, % <-- CUT!  % if the variables has been previously registered
    match(RestElements, NextWords, Map2, MapN, RestSelected).
match([Element|RestElements], ['['|PossibleLiteral], Map1, MapN, [Term|RestSelected]) :-
    var(Element), stop_words(RestElements, StopWords),
    extract_list([']'|StopWords], List, Map1, Map2, PossibleLiteral, [']'|NextWords]),  % matching brackets verified
    %print_message(informational, "List ~w"-[List]),  
    correct_list(List, Term), 
    match(RestElements, NextWords, Map2, MapN, RestSelected).
% enabling expressions and constants
match([Element|RestElements], [Word|PossibleLiteral], Map1, MapN, [Expression|RestSelected]) :-
    var(Element), stop_words(RestElements, StopWords),
    %print_message(informational, [Word|PossibleLiteral]),
    extract_expression([','|StopWords], NameWords, [Word|PossibleLiteral], NextWords), NameWords \= [],
    %print_message(informational, "Expression? ~w"-[NameWords]),
    % this expression cannot add variables 
    ( phrase(expression_(Expression, Map1, _), NameWords) -> true ; ( name_predicate(NameWords, Expression) ) ),
    %print_message(informational, 'found a constant or an expression '), print_message(informational, Expression),
    match(RestElements, NextWords, Map1, MapN, RestSelected). 

correct_list([], []) :- !. 
correct_list([A,B], [A,B]) :- atom(B), !. % not(is_list(B)), !. 
correct_list([A,B], [A|B] ) :- !. 
correct_list([A|B], [A|NB]) :- correct_list(B, NB). 

% expression/3 or /5
%expression_(List, MapIn, MapOut) --> list_(List, MapIn, MapOut), !. 
% expression_ resolve simple math (non boolean) expressions fttb. 
% dates must be dealt with first  
% 2021-02-06T08:25:34 is transformed into 1612599934.0.
expression_(DateInSeconds, Map, Map) --> 
    [Year,'-', Month, '-', DayTHours,':', Minutes, ':', Seconds], spaces(_),
    { concat_atom([Year,'-', Month, '-', DayTHours,':', Minutes, ':', Seconds], '', Date), 
      parse_time(Date,DateInSeconds) %, print_message(informational, "~w"-[DateInSeconds])  
    }, !.
% 2021-02-06
expression_(DateInSeconds, Map, Map) -->  [Year,'-', Month, '-', Day],  spaces(_),
    { concat_atom([Year, Month, Day], '', Date), parse_time(Date, DateInSeconds) }, !. 
% basic float  extracted from atoms from the tokenizer
expression_(Float, Map, Map) --> [AtomNum,'.',AtomDecimal],
        { atom(AtomNum), atom(AtomDecimal), atomic_list_concat([AtomNum,'.',AtomDecimal], Atom), atom_number(Atom, Float) }, !.
% mathematical expressions
expression_(InfixBuiltIn, Map1, MapN) --> 
    %{print_message(informational, "Binary exp map ~w"-[Map1])}, 
    {op_stop(Stop)}, term_(Stop, Term, Map1, Map2), spaces(_), binary_op(BuiltIn), !, 
    %{print_message(informational, "Binary exp first term ~w and op ~w"-[Term, BuiltIn])}, 
    spaces(_), expression_(Expression, Map2, MapN), spaces(_), 
    {InfixBuiltIn =.. [BuiltIn, Term, Expression]}. %, print_message(informational, "Binary exp ~w"-InfixBuiltIn)}.  
% a quick fix for integer numbers extracted from atoms from the tokenizer
expression_(Number, Map, Map) --> [Atom],  spaces(_), { atom(Atom), atom_number(Atom, Number) }, !. 
expression_(Var, Map1, Map2) -->  {op_stop(Stop)}, variable(Stop, Var, Map1, Map2),!.%, {print_message(informational, "Just var ~w"-Var)}, 
expression_(Constant, Map1, Map2) -->  {op_stop(Stop)}, constant(Stop, Constant, Map1, Map2).%, {print_message(informational, "Constant ~w"-Constant)}.     
% error clause
expression(_, _, _, Rest, _) :- 
    asserterror('LE error found in an expression ', Rest), fail.

% only one word operators
%binary_op(Op) --> [Op], { atom(Op), current_op(_Prec, Fix, Op),
%    Op \= '.',
%    (Fix = 'xfx'; Fix='yfx'; Fix='xfy'; Fix='yfy') }.

% operators with any amout of words/symbols
% binary_op/3
binary_op(Op, In, Out) :-
    op2tokens(Op, OpTokens, _),
    append(OpTokens, Out, In).

% very inefficient. Better to compute and store. See below
op_tokens(Op, OpTokens) :-
    current_op(_Prec, Fix, Op), Op \= '.',
    (Fix = 'xfx'; Fix='yfx'; Fix='xfy'; Fix='yfy'),
    term_string(Op, OpString), tokenize(OpString, Tokens, [cased(true), spaces(true), numbers(false)]),
    unpack_tokens(Tokens, OpTokens).

% findall(op2tokens(Op, OpTokens, OpTokens), op_tokens(Op, OpTokens), L), forall(member(T,L), (write(T),write('.'), nl)).
% op2tokens(+Operator, PrologTokens, sCASPTokens)
% op2tokens/3
op2tokens(is_not_before,[is_not_before],[is_not_before]).
op2tokens(of,[of],[of]).
op2tokens(if,[if],[if]).
op2tokens(then,[then],[then]).
op2tokens(must,[must],[must]).
op2tokens(on,[on],[on]).
op2tokens(because,[because],[because]).
op2tokens(and,[and],[and]).
op2tokens(in,[in],[in]).
op2tokens(or,[or],[or]).
op2tokens(at,[at],[at]).
op2tokens(before,[before],[before]).
op2tokens(after,[after],[after]).
op2tokens(else,[else],[else]).
op2tokens(with,[with],[with]).
op2tokens(::,[:,:],[:,:]).
op2tokens(->,[-,>],[-,>]).
op2tokens(:,[:],[:]).
op2tokens(,,[',,,'],[',,,']).
op2tokens(:=,[:,=],[:,=]).
op2tokens(==,[=,=],[=,=]).
op2tokens(:-,[:,-],[:,-]).
op2tokens(/\,[/,\],[/,\]).
op2tokens(=,[=],[=]).
op2tokens(rem,[rem],[rem]).
op2tokens(is,[is],[is]).
op2tokens(=:=,[=,:,=],[=,:,=]).
op2tokens(=\=,[=,\,=],[=,\,=]).
op2tokens(xor,[xor],[xor]).
op2tokens(as,[as],[as]).
op2tokens(rdiv,[rdiv],[rdiv]).
op2tokens(>=,[>,=],[>,=]).
op2tokens(@<,[@,<],[@,<]).
op2tokens(@=<,[@,=,<],[@,=,<]).
op2tokens(=@=,[=,@,=],[=,@,=]).
op2tokens(\=@=,[\,=,@,=],[\,=,@,=]).
op2tokens(@>,[@,>],[@,>]).
op2tokens(@>=,[@,>,=],[@,>,=]).
op2tokens(\==,[\,=,=],[\,=,=]).
op2tokens(\=,[\,=],[\,=]).
op2tokens(>,[>],[>]).
%op2tokens(|,[',|,'],[',|,']).
op2tokens('|',['|'],['|']).
op2tokens(\/,[\,/],[\,/]).
op2tokens(+,[+],[+]).
op2tokens(>>,[>,>],[>,>]).
op2tokens(;,[;],[;]).
op2tokens(<<,[<,<],[<,<]).
op2tokens(:<,[:,<],[:,<]).
op2tokens(>:<,[>,:,<],[>,:,<]).
op2tokens(/,[/],[/]).
op2tokens(=>,[=,>],[=,>]).
op2tokens(=..,[=,.,.],[=,.,.]).
op2tokens(div,[div],[div]).
op2tokens(//,[/,/],[/,/]).
op2tokens(**,[*,*],[*,*]).
op2tokens(*,[*],[*]).
op2tokens(^,[^],[^]).
op2tokens(mod,[mod],[mod]).
op2tokens(-,[-],[-]).
op2tokens(*->,[*,-,>],[*,-,>]).
op2tokens(<,[<],[<]).
op2tokens(=<,[=,<],[=,<]).
op2tokens(-->,[-,-,>],[-,-,>]).

% very inefficient. Better to compute and store. See below
op_stop_words(Words) :-
    op_stop(Words) -> true; (    
        findall(Word, 
            (current_op(_Prec, _, Op), Op \= '.', % don't include the period!
            term_string(Op, OpString), 
            tokenize(OpString, Tokens, [cased(true), spaces(true), numbers(false)]),
            unpack_tokens(Tokens, [Word|_])), Words), % taking only the first word as stop word 
        assertz(op_stop(Words))
        ), !. 

op_stop([ (on), 
        (because),
        (is_not_before),
        (not),
        (before),
        (and),
        (or),
        (at),
        (html_meta),
        (after),
        (in),
        (else),
        (+),
        (then),
        (must),
        (if),
        (if),
        ($),
        (\),
        (=),
        (thread_initialization),
        (:),
        (\),
        '\'',
        (xor),
        (:),
        (rem),
        (\),
        (table),
        (initialization),
        (rdiv),
        (/),
        (>),
        (>),
        (=),
        (=),
        (;),
        (as),
        (is),
        (=),
        @,
        @,
        @,
        @,
        (\),
        (thread_local),
        (>),
        (=),
        (<),
        (*),
        '\'',
        (=),
        (\),
        (\),
        (+),
        (+),
        (:),
        (>),
        (div),
        (discontiguous),
        (<),
        (/),
        (meta_predicate),
        (=),
        (-),
        (-),
        (volatile),
        (public),
        (-),
        (:),
        (:),
        (*),
        ?,
        (/),
        (*),
        (-),
        (multifile),
        (dynamic),
        (mod),
        (^),
        (module_transparent)
      ]).

stop_words([], []).
stop_words([Word|_], [Word]) :- nonvar(Word). % only the next word for now
stop_words([Word|_], []) :- var(Word).

% list_symbol/1: a symbol specific for list that can be used as stop word for others
list_symbol('[').
list_symbol(']'). 

extract_literal(_, [], [], []) :- !. 
extract_literal(StopWords, [],  [Word|RestOfWords],  [Word|RestOfWords]) :-
    (member(Word, StopWords); that_(Word); phrase(newline, [Word])), !. 
extract_literal(SW, RestName, [' '|RestOfWords],  NextWords) :- !, % skipping spaces
    extract_literal(SW, RestName, RestOfWords, NextWords).
extract_literal(SW, RestName, ['\t'|RestOfWords],  NextWords) :- !, 
    extract_literal(SW, RestName, RestOfWords, NextWords).
extract_literal(SW, [Word|RestName], [Word|RestOfWords],  NextWords) :-
    extract_literal(SW, RestName, RestOfWords, NextWords).

% extract_variable_template/7
% extract_variable_template(+StopWords, +InitialNameWords, -FinalNameWords, +InitialTypeWords, -FinalTypeWords, +ListOfWords, -NextWordsInText)
% refactored as a dcg predicate
extract_variable_template(_, Names, Names, Types, Types, [], []) :- !.                                % stop at when words run out
extract_variable_template(StopWords, Names, Names, Types, Types, [Word|RestOfWords], [Word|RestOfWords]) :-   % stop at reserved words, verbs or prepositions. 
    %(member(Word, StopWords); reserved_word(Word); verb(Word); preposition(Word); punctuation(Word); phrase(newline, [Word])), !.  % or punctuation
    (member(Word, StopWords); that_(Word); list_symbol(Word); punctuation(Word); phrase(newline, [Word])), !.
extract_variable_template(SW, InName, OutName, InType, OutType, [' '|RestOfWords], NextWords) :- !, % skipping spaces
    extract_variable_template(SW, InName, OutName, InType, OutType, RestOfWords, NextWords).
extract_variable_template(SW, InName, OutName, InType, OutType, ['\t'|RestOfWords], NextWords) :- !, % skipping spaces
    extract_variable_template(SW, InName, OutName, InType, OutType, RestOfWords, NextWords).  
extract_variable_template(SW, InName, OutName, InType, OutType, [Word|RestOfWords], NextWords) :- % ordinals are not part of the type
    ordinal(Word), !, 
    extract_variable_template(SW, [Word|InName], OutName, InType, OutType, RestOfWords, NextWords).
%extract_variable_template(SW, InName, OutName, InType, OutType, [Word|RestOfWords], NextWords) :- % types are not part of the name
%    is_a_type(Word),
%    extract_variable(SW, InName, NextName, InType, OutType, RestOfWords, NextWords),
%    (NextName = [] -> OutName = [Word]; OutName = NextName), !.
extract_variable_template(SW, InName, [Word|OutName], InType, [Word|OutType], [Word|RestOfWords], NextWords) :- % everything else is part of the name (for instances) and the type (for templates)
    extract_variable_template(SW, InName, OutName, InType, OutType, RestOfWords, NextWords).

% extract_variable/7
% extract_variable(+StopWords, +InitialNameWords, -FinalNameWords, +InitialTypeWords, -FinalTypeWords, +ListOfWords, -NextWordsInText)
% refactored as a dcg predicate
extract_variable(_, Names, Names, Types, Types, [], []) :- !.                                % stop at when words run out
extract_variable(StopWords, Names, Names, Types, Types, [Word|RestOfWords], [Word|RestOfWords]) :-   % stop at reserved words, verbs or prepositions. 
    %(member(Word, StopWords); reserved_word(Word); verb(Word); preposition(Word); punctuation(Word); phrase(newline, [Word])), !.  % or punctuation
    (member(Word, StopWords); that_(Word); list_symbol(Word); punctuation(Word); phrase(newline, [Word])), !.
extract_variable(SW, InName, OutName, InType, OutType, [' '|RestOfWords], NextWords) :- !, % skipping spaces
    extract_variable(SW, InName, OutName, InType, OutType, RestOfWords, NextWords).
extract_variable(SW, InName, OutName, InType, OutType, ['\t'|RestOfWords], NextWords) :- !, % skipping spaces
    extract_variable(SW, InName, OutName, InType, OutType, RestOfWords, NextWords).  
extract_variable(SW, InName, OutName, InType, OutType, [Word|RestOfWords], NextWords) :- % ordinals are not part of the type
    ordinal(Word), !, 
    extract_variable(SW, [Word|InName], OutName, InType, OutType, RestOfWords, NextWords).
extract_variable(SW, InName, OutName, InType, OutType, [Word|RestOfWords], NextWords) :- % types are not part of the name
    is_a_type(Word),
    extract_variable(SW, InName, NextName, InType, OutType, RestOfWords, NextWords),
    (NextName = [] -> OutName = [Word]; OutName = NextName), !.
extract_variable(SW, InName, [Word|OutName], InType, [Word|OutType], [Word|RestOfWords], NextWords) :- % everything else is part of the name (for instances) and the type (for templates)
    extract_variable(SW, InName, OutName, InType, OutType, RestOfWords, NextWords).

% extract_expression/4
% extract_expression(+StopWords, ListOfNameWords, +ListOfWords, NextWordsInText)
% it does not stop at reserved words!
extract_expression(_, [], [], []) :- !.                                % stop at when words run out
extract_expression(StopWords, [], [Word|RestOfWords], [Word|RestOfWords]) :-   % stop at  verbs? or prepositions?. 
    (member(Word, StopWords); that_(Word); list_symbol(Word); phrase(newline, [Word])), !.  
%extract_expression([Word|RestName], [Word|RestOfWords], NextWords) :- % ordinals are not part of the name
%    ordinal(Word), !,
%    extract_constant(RestName, RestOfWords, NextWords).
extract_expression(SW, RestName, [' '|RestOfWords],  NextWords) :- !, % skipping spaces
    extract_expression(SW, RestName, RestOfWords, NextWords).
extract_expression(SW, RestName, ['\t'|RestOfWords],  NextWords) :- !, 
    extract_expression(SW, RestName, RestOfWords, NextWords).
extract_expression(SW, [Word|RestName], [Word|RestOfWords],  NextWords) :-
    %is_a_type(Word),
    %not(determiner(Word)), % no determiners inside constants!
    extract_expression(SW, RestName, RestOfWords, NextWords).

% extract_constant/4
% extract_constant(+StopWords, ListOfNameWords, +ListOfWords, NextWordsInText)
extract_constant(_, [], [], []) :- !.                                % stop at when words run out
extract_constant(StopWords, [], [Word|RestOfWords], [Word|RestOfWords]) :-   % stop at reserved words, verbs? or prepositions?. 
    %(member(Word, StopWords); reserved_word(Word); verb(Word); preposition(Word); punctuation(Word); phrase(newline, [Word])), !.  % or punctuation
    (member(Word, StopWords); that_(Word); list_symbol(Word); punctuation(Word); phrase(newline, [Word])), !.
%extract_constant([Word|RestName], [Word|RestOfWords], NextWords) :- % ordinals are not part of the name
%    ordinal(Word), !,
%    extract_constant(RestName, RestOfWords, NextWords).
extract_constant(SW, RestName, [' '|RestOfWords],  NextWords) :- !, % skipping spaces
    extract_constant(SW, RestName, RestOfWords, NextWords).
extract_constant(SW, RestName, ['\t'|RestOfWords],  NextWords) :- !, 
    extract_constant(SW, RestName, RestOfWords, NextWords).
extract_constant(SW, [Word|RestName], [Word|RestOfWords],  NextWords) :-
    %is_a_type(Word),
    %not(determiner(Word)), % no determiners inside constants!
    extract_constant(SW, RestName, RestOfWords, NextWords).

% extract_list/6
% extract_list(+StopWords, -List, +Map1, -Map2, +[Word|PossibleLiteral], -NextWords),
extract_list(SW, [], Map, Map, [Word|Rest], [Word|Rest]) :- 
    lists:member(Word, SW), !. % stop but leave the symbol for further verification
%extract_list(_, [], Map, Map, [')'|Rest], [')'|Rest]) :- !. 
extract_list(SW, RestList, Map1, MapN, [' '|RestOfWords],  NextWords) :- !, % skipping spaces
    extract_list(SW, RestList, Map1, MapN, RestOfWords, NextWords).
extract_list(SW, RestList, Map1, MapN, [' '|RestOfWords],  NextWords) :- !, % skipping spaces
    extract_list(SW, RestList, Map1, MapN, RestOfWords, NextWords).
extract_list(SW, RestList, Map1, MapN, ['\t'|RestOfWords],  NextWords) :- !, 
    extract_list(SW, RestList, Map1, MapN, RestOfWords, NextWords).
extract_list(SW, RestList, Map1, MapN, [','|RestOfWords],  NextWords) :- !, % skip over commas
    extract_list(SW, RestList, Map1, MapN, RestOfWords, NextWords).
extract_list(SW, RestList, Map1, MapN, ['|'|RestOfWords],  NextWords) :- !, % skip over commas
    extract_list(SW, RestList, Map1, MapN, RestOfWords, NextWords).
extract_list(StopWords, List, Map1, MapN, [Det|InWords], LeftWords) :-
    phrase(indef_determiner, [Det|InWords], RInWords), 
    extract_variable(['|'|StopWords], [], NameWords, [], _, RInWords, NextWords), NameWords \= [], % <- leave that _ unbound!
    name_predicate(NameWords, Name),  
    update_map(Var, Name, Map1, Map2),
    (NextWords = [']'|_] -> (RestList = [], LeftWords=NextWords, MapN=Map2 ) ; 
    extract_list(StopWords, RestList, Map2, MapN, NextWords, LeftWords) ), 
    (RestList=[] -> List=[Var|[]]; List=[Var|RestList]), 
    !.
extract_list(StopWords, List, Map1, MapN, [Det|InWords], LeftWords) :-
    phrase(def_determiner, [Det|InWords], RInWords), 
    extract_variable(['|'|StopWords], [], NameWords, [], _, RInWords, NextWords), NameWords \= [], % <- leave that _ unbound!
    name_predicate(NameWords, Name),  
    consult_map(Var, Name, Map1, Map2), 
    (NextWords = [']'|_] -> (RestList = [], LeftWords=NextWords, MapN=Map2 ) ;
    extract_list(StopWords, RestList, Map2, MapN, NextWords, LeftWords) ), 
    (RestList=[] -> List=[Var|[]]; List=[Var|RestList]), !.
extract_list(StopWords, List, Map1, MapN, InWords, LeftWords) :- % symbolic variables without determiner
    extract_variable(['|'|StopWords], [], NameWords, [], _, InWords, NextWords), NameWords \= [],  % <- leave that _ unbound!
    name_predicate(NameWords, Name),  
    consult_map(Var, Name, Map1, Map2), 
    (NextWords = [']'|_] -> (RestList = [], LeftWords=NextWords, MapN=Map2 ) ; 
    extract_list(StopWords, RestList, Map2, MapN, NextWords, LeftWords) ), 
    (RestList=[] -> List=[Var|[]]; List=[Var|RestList]), !.
extract_list(StopWords, List, Map1, MapN, InWords, LeftWords) :-
    extract_expression(['|',','|StopWords], NameWords, InWords, NextWords), NameWords \= [], 
    ( phrase(expression_(Expression, Map1, Map2), NameWords) -> true 
    ; ( Map1 = Map2, name_predicate(NameWords, Expression) ) ),
    ( NextWords = [']'|_] -> ( RestList = [], LeftWords=NextWords, MapN=Map2 ) 
    ;    extract_list(StopWords, RestList, Map2, MapN, NextWords, LeftWords) ), 
    (RestList=[] -> List=[Expression|[]]; List=[Expression|RestList]), !.

determiner --> ind_det, !.
determiner --> ind_det_C, !.
determiner --> def_det, !.
determinar --> def_det_C. 

indef_determiner --> ind_det, !.
indef_determiner --> ind_det_C. 

def_determiner --> def_det, !.
def_determiner --> def_det_C. 

rebuild_template(RawTemplate, Map1, MapN, Template) :-
    template_elements(RawTemplate, Map1, MapN, [], Template).

% template_elements(+Input,+InMap, -OutMap, +Previous, -Template)
template_elements([], Map1, Map1, _, []).     
template_elements([Word|RestOfWords], Map1, MapN, Previous, [Var|RestTemplate]) :-
    (phrase(ind_det, [Word|RestOfWords], RRestOfWords); phrase(ind_det_C,[Word|RestOfWords], RRestOfWords)), Previous \= [is|_], 
    extract_variable([], [], NameWords, [], _, RRestOfWords, NextWords), !, % <-- CUT!
    name_predicate(NameWords, Name), 
    update_map(Var, Name, Map1, Map2), 
    template_elements(NextWords, Map2, MapN, [], RestTemplate).
template_elements([Word|RestOfWords], Map1, MapN, Previous, [Var|RestTemplate]) :-
    (phrase(def_det, [Word|RestOfWords], RRestOfWords); phrase(def_det_C,[Word|RestOfWords], RRestOfWords)), Previous \= [is|_], 
    extract_variable([], [], NameWords, [], _, RRestOfWords, NextWords), !, % <-- CUT!
    name_predicate(NameWords, Name), 
    member(map(Var,Name), Map1),  % confirming it is an existing variable and unifying
    template_elements(NextWords, Map1, MapN, [], RestTemplate).
template_elements([Word|RestOfWords], Map1, MapN, Previous, [Word|RestTemplate]) :-
    template_elements(RestOfWords, Map1, MapN, [Word|Previous], RestTemplate).

% update_map/4
% update_map(?V, +Name, +InMap, -OutMap)
update_map(V, Name, InMap, InMap) :- 
    var(V), nonvar(Name), nonvar(InMap), 
    member(map(O,Name), InMap), O\==V, fail, !. 
update_map(V, Name, InMap, OutMap) :-  % updates the map by adding a new variable into it. 
    var(V), nonvar(Name), nonvar(InMap), 
    not(member(map(_,Name), InMap)), 
    OutMap = [map(V,Name)|InMap]. 
%update_map(V, _, Map, Map) :-
%    nonvar(V). 

% consult_map/4
% consult_map(+V, -Name, +Inmap, -OutMap)
consult_map(V, Name, InMap, InMap) :-
    member(map(Var, SomeName), InMap), (Name == SomeName -> Var = V; ( Var == V -> Name = SomeName ; fail ) ),  !.  
%consult_map(V, V, Map, Map). % leave the name unassigned % deprecated to be used inside match

builtin_(BuiltIn, [BuiltIn1, BuiltIn2|RestWords], RestWords) :- 
    atom_concat(BuiltIn1, BuiltIn2, BuiltIn), 
    Predicate =.. [BuiltIn, _, _],  % only binaries fttb
    predicate_property(system:Predicate, built_in), !.
builtin_(BuiltIn, [BuiltIn|RestWords], RestWords) :- 
    Predicate =.. [BuiltIn, _, _],  % only binaries fttb
    predicate_property(system:Predicate, built_in). 

/* --------------------------------------------------------- Utils in Prolog */
time_of(P, T) :- P=..[_|Arguments], lists:append(_, [T], Arguments). % it assumes time as the last argument

% Unwraps tokens, excelt for newlines which become newline(NextLineNumber)
unpack_tokens([], []).
unpack_tokens([cntrl(Char)|Rest], [newline(Next)|NewRest]) :- (Char=='\n' ; Char=='\r'), !,
    %not sure what will happens on env that use \n\r
    update_nl_count(Next), unpack_tokens(Rest, NewRest).
unpack_tokens([First|Rest], [New|NewRest]) :-
    (First = word(New); First=cntrl(New); First=punct(New); First=space(New); First=number(New); First=string(New)), 
     !,
    unpack_tokens(Rest, NewRest).  

% increments the next line number
update_nl_count(NN) :- retract(last_nl_parsed(N)), !, NN is N + 1, assert(last_nl_parsed(NN)). 

ordinal(Ord) :-
    ordinal(_, Ord). 

ordinal(1,  'first').
ordinal(2,  'second').
ordinal(3,  'third').
ordinal(4,  'fourth').
ordinal(5,  'fifth').
ordinal(6,  'sixth').
ordinal(7,  'seventh').
ordinal(8,  'eighth').
ordinal(9,  'ninth').
ordinal(10, 'tenth').
% french
ordinal(1, 'premier').
ordinal(2, 'seconde').
ordinal(3, 'troisième').
ordinal(4, 'quatrième').
ordinal(5, 'cinquième').
ordinal(6, 'sixième').
ordinal(7, 'septième').
ordinal(8, 'huitième').
ordinal(9, 'neuvième').
ordinal(10, 'dixième'). 

%is_a_type/1
is_a_type(T) :- % pending integration with wei2nlen:is_a_type/1
   %ground(T),
   (is_type(T); pre_is_type(T)), !. 
   %(T=time; T=date; T=number; T=person; T=day). % primitive types to start with
   %not(number(T)), not(punctuation(T)),
   %not(reserved_word(T)),
   %not(verb(T)),
   %not(preposition(T)). 

/* ------------------------------------------------ determiners */

ind_det_C --> ['A'].
ind_det_C --> ['An'].
ind_det_C --> ['Un'].     % spanish, italian, and french
ind_det_C --> ['Una'].    % spanish, italian
ind_det_C --> ['Une'].    % french
ind_det_C --> ['Qui'].    % french which? 
ind_det_C --> ['Quoi'].    % french which? 
ind_det_C --> ['Uno'].    % italian
ind_det_C --> ['Che']. % italian which
ind_det_C --> ['Quale']. % italian which
% ind_det_C('Some').
ind_det_C --> ['Each'].   % added experimental
ind_det_C --> ['Which'].  % added experimentally

def_det_C --> ['The'].
def_det_C --> ['El'].  % spanish
def_det_C --> ['La'].  % spanish, italian, and french
def_det_C --> ['Le'].  % french
def_det_C --> ['L'], [A], {atom_string(A, "'")}.   % french
def_det_C --> ['Il'].  % italian
def_det_C --> ['Lo'].  % italian

ind_det --> [a].
ind_det --> [an].
ind_det --> [another]. % added experimentally
ind_det --> [which].   % added experimentally
ind_det --> [each].    % added experimentally
ind_det --> [un].      % spanish, italian, and french
ind_det --> [una].     % spanish, italian
ind_det --> [une].     % french
ind_det --> [qui].     % french which?
ind_det --> [quoi].    % french which?
ind_det --> [che]. % italian which
ind_det --> [quale]. % italian which
ind_det --> [uno].     % italian
% ind_det(some).

def_det --> [the].
def_det --> [el].     % spanish
def_det --> [la].     % spanish, italian and french
def_det --> [le].     % french
def_det --> [l], [A], {atom_string(A, "'")}.  % french, italian
def_det --> [il].     % italian
def_det --> [lo].     % italian

/* ------------------------------------------------ reserved words */
reserved_word(W) :- % more reserved words pending??
    W = 'is'; W ='not'; W='if'; W='If'; W='then'; W = 'where';  W = '&'; % <- hack!
    W = 'at'; W= 'from'; W='to';  W='half'; % W='or'; W='and'; % leaving and/or out of this for now
    W = 'else'; W = 'otherwise'; 
    W = such ; 
    W = '<'; W = '='; W = '>';  W = '+'; W = '-'; W = '/'; W = '*'; % these are handled by extract_expression
    W = '{' ; W = '}' ; W = '(' ; W = ')' ; W = '[' ; W = ']',
    W = ':', W = ','; W = ';'. % these must be handled by parsing
reserved_word(P) :- punctuation(P).

that_(that).
that_('That'). 

/* ------------------------------------------------ punctuation */
%punctuation(punct(_P)).

punctuation('.').
punctuation(',').
punctuation(';').
%punctuation(':').
punctuation('\'').

/* ------------------------------------------------ verbs */
verb(Verb) :- present_tense_verb(Verb); continuous_tense_verb(Verb); past_tense_verb(Verb). 

present_tense_verb(is).
present_tense_verb(complies). 
present_tense_verb(does). 
present_tense_verb(occurs).
present_tense_verb(meets).
present_tense_verb(relates).
present_tense_verb(can).
present_tense_verb(qualifies).
present_tense_verb(has).
present_tense_verb(satisfies).
present_tense_verb(owns).
present_tense_verb(belongs).
present_tense_verb(applies).
present_tense_verb(must).
present_tense_verb(acts).
present_tense_verb(falls).
present_tense_verb(corresponds). 
present_tense_verb(likes). 

continuous_tense_verb(according).
continuous_tense_verb(beginning).
continuous_tense_verb(ending).

past_tense_verb(spent). 
past_tense_verb(looked).
past_tense_verb(could).
past_tense_verb(had).
past_tense_verb(tried).
past_tense_verb(explained).
past_tense_verb(ocurred).
 
/* ------------------------------------------------- prepositions */
preposition(of).
%preposition(on).
preposition(from).
preposition(to).
preposition(at).
preposition(in).
preposition(with).
preposition(plus).
preposition(as).
preposition(by).

/* ------------------------------------------------- memory handling */
assertall([]).
assertall([F|R]) :-
    not(asserted(F)),
    %print_message(informational, "Asserting"-[F]),
    assertz(F), !,
    assertall(R).
assertall([_F|R]) :-
    assertall(R).

asserted(F :- B) :- clause(F, B). % as a rule with a body
asserted(F) :- clause(F,true). % as a fact

/* -------------------------------------------------- error handling */
currentLine(LineNumber, Rest, Rest) :-
    once( nth1(_,Rest,newline(NextLine)) ), LineNumber is NextLine-2. 

% assert_error_os/1
% to save final error to be displayed
assert_error_os([]) :- !. 
assert_error_os([error(Message, LineNumber, Tokens)|Re]) :-
    asserta(error_notice(error, Message, LineNumber, Tokens)),
    assert_error_os(Re).

asserterror(Me, Rest) :-
    %print_message(error, ' Error found'), 
    %select_first_section(Rest, 40, Context), 
    %retractall(error_notice(_,_,_,_)), % we will report only the last
    once( nth1(N,Rest,newline(NextLine)) ), LineNumber is NextLine-2,
    RelevantN is N-1,
    length(Relevant,RelevantN), append(Relevant,_,Rest),
    findall(Token, (member(T,Relevant), (T=newline(_) -> Token='\n' ; Token=T)), Tokens),
    asserta(error_notice(error, Me, LineNumber, Tokens)). % asserting the last first!

% to select just a chunck of Rest to show. 
select_first_section([], _, []) :- !.
select_first_section(_, 0, []) :- !. 
select_first_section([E|R], N, [E|NR]) :-
    N > 0, NN is N - 1,
    select_first_section(R, NN, NR). 

showErrors(File,Baseline) :- % showing the deepest message!
    findall(error_notice(error, Me,Pos, ContextTokens), 
        error_notice(error, Me,Pos, ContextTokens), ErrorsList),
    deepest(ErrorsList, 
        error_notice(error, 'None',0, ['There was no syntax error']), 
        error_notice(error, MeMax,PosMax, ContextTokensMax)), 
    atomic_list_concat([MeMax,': '|ContextTokensMax],ContextTokens_),
    Line is PosMax+Baseline,
    print_message(error,error(syntax_error(ContextTokens_),file(File,Line,_One,_Char))).
    % to show them all
    %forall(error_notice(error, Me,Pos, ContextTokens), (
    %    atomic_list_concat([Me,': '|ContextTokens],ContextTokens_),
    %    Line is Pos+Baseline,
    %    print_message(error,error(syntax_error(ContextTokens_),file(File,Line,_One,_Char)))
    %    )).

deepest([], Deepest, Deepest) :- !.
deepest([error_notice(error, Me,Pos, ContextTokens)|Rest], 
        error_notice(error,_Me0, Pos0,_ContextTokens0), Out) :-
    Pos0 < Pos, !, 
    deepest(Rest, error_notice(error, Me,Pos, ContextTokens), Out).
deepest([_|Rest], In, Out) :-
    deepest(Rest, In, Out).

showProgress :-
    findall(error_notice(error, Me,Pos, ContextTokens), 
        error_notice(error, Me,Pos, ContextTokens), ErrorsList),
    deepest(ErrorsList, 
        error_notice(error, 'None',0, ['There was no syntax error']), 
        error_notice(error, MeMax,PosMax, ContextTokensMax)), 
    atomic_list_concat([MeMax,': '|ContextTokensMax],ContextTokens_),
    Line is PosMax+1,
    print_message(informational,error(syntax_error(ContextTokens_),file(someFile,Line,_One,_Char))).


spypoint(A,A). % for debugging

% meta_dictionary(?LiteralElements, ?NamesAndTypes, ?Template)
% for meta templates. See below
% meta_dictionary/1
meta_dictionary(Predicate, VariablesNames, Template) :- 
    meta_dict(Predicate, VariablesNames, Template) ; predef_meta_dict(Predicate, VariablesNames, Template).

:- discontiguous predef_meta_dict/3.
predef_meta_dict([\=, T1, T2], [first_thing-time, second_thing-time], [T1, is, different, from, T2]).
predef_meta_dict([=, T1, T2], [first_thing-time, second_thing-time], [T1, is, equal, to, T2]).

% dictionary(?LiteralElements, ?NamesAndTypes, ?Template)
% this is a multimodal predicate used to associate a Template with its particular other of the words for LE
% with the Prolog expression of that relation in LiteralElements (not yet a predicate, =.. is done elsewhere).
% NamesAndTypes contains the external name and type (name-type) of each variable just in the other in 
% which the variables appear in LiteralElement. 
% dictionary/1
dictionary(Predicate, VariablesNames, Template) :- % dict(Predicate, VariablesNames, Template).
    dict(Predicate, VariablesNames, Template) ; predef_dict(Predicate, VariablesNames, Template).
%    predef_dict(Predicate, VariablesNames, Template); dict(Predicate, VariablesNames, Template).

:- discontiguous predef_dict/3.
% predef_dict/3 is a database with predefined templates for LE
% it must be ordered by the side of the third argument, to allow the system to check first the longer template
% with the corresponding starting words. 
% for Taxlog examples
predef_dict(['\'s_R&D_expense_credit_is', Project, ExtraDeduction, TaxCredit], 
                                 [project-projectid, extra-amount, credit-amount],
   [Project, '\'s', 'R&D', expense, credit, is, TaxCredit, plus, ExtraDeduction]).
predef_dict(['can_request_R&D_relief_such_as', Project, ExtraDeduction, TaxCredit], 
                                 [project-projectid, extra-amount, credit-amount],
   [Project, can, request,'R&D', relief, for, a, credit, of, TaxCredit, with, a, deduction, of, ExtraDeduction]).
predef_dict(['\'s_sme_R&D_relief_is', Project, ExtraDeduction, TaxCredit], 
                                 [project-projectid, extra-amount, credit-amount],
   [the, 'SME', 'R&D', relief, for, Project, is, estimated, at, TaxCredit, with, an, extra, of, ExtraDeduction]).
predef_dict([project_subject_experts_list_is,Project,Experts], [project-object, experts_list-list],
   [Project, has, an, Experts, list]).
predef_dict([rollover_applies,EventID,Asset,Time,Transferor,TransfereesList], [id-event,asset-asset,when-time,from-person,to-list], 
   [EventID, rollover, of, the, transfer, of, Asset, from, Transferor, to, TransfereesList, at, Time, applies]).
predef_dict([transfer_event,ID,Asset,Time,Transferor,TransfereesList],[id-id,asset-asset,time-time,from-person,to-list],
   [event, ID, of, transfering, Asset, from, Transferor, to, TransfereesList, at, Time, occurs]).
predef_dict([s_type_and_liability_are(Asset,Type,Liability), [asset-asset, assettype-type, liabilty-amount],
   [the, type, of, asset, Asset, is, Type, its, liability, is, Liability]]).
predef_dict([exempt_transfer,From,To,SecurityIdentifier,Time],[from-taxpayer,to-taxpayer,secID-number, time-time],
   [a, transfer, from, From, to, To, with, SecurityIdentifier, at, Time, is, exempt]).
predef_dict([shares_transfer,Sender,Recipient,SecurityID,Time], [from-person, to-person, id-number, time-time], 
   [Sender, transfers, shares, to, Recipient, at, Time, with, id, SecurityID]).
predef_dict([trading_in_market,SecurityID,MarketID,Time], [id-number,market-number,time-time], 
   [whoever, is, identified,by, SecurityID, is, trading, in, market, MarketID, at, Time]).
predef_dict([uk_tax_year_for_date,Date,Year,Start,End], [date-date,year-year,start-date,end-date], 
   [date, Date, falls, in, the, 'UK', tax, year, Year, that, starts, at, Start, ends, at, End]).
predef_dict([days_spent_in_uk,Individual,Start,End,TotalDays], [who-person,start-date,end-date,total-number], 
   [Individual, spent, TotalDays, days, in, the, 'UK', starting, at, Start, ending, at, End]).
predef_dict([days_spent_in_uk,Individual,Start,End,TotalDays], [who-person,start-date,end-date,total-number], 
                   [Individual, spent, TotalDays, in, the, 'UK', starting, at, Start, &, ending, at, End]). 
predef_dict([uk_tax_year_for_date,Date,Year,Start,End], [first_date-date, year-year, second_date-date, third_date-date], 
                   [in, the, 'UK', Date, falls, in, Year, beginning, at, Start, &, ending, at, End]).
predef_dict([is_individual_or_company_on, A, B],
                   [affiliate-affiliate, date-date],
                   [A, is, an, individual, or, is, a, company, at, B]).
% Prolog
predef_dict([has_as_head_before, A, B, C], [list-list, symbol-term, rest_of_list-list], [A, has, B, as, head, before, C]).
predef_dict([append, A, B, C],[first_list-list, second_list-list, third_list-list], [appending, A, then, B, gives, C]).
predef_dict([reverse, A, B], [list-list, other_list-list], [A, is, the, reverse, of, B]).
predef_dict([same_date, T1, T2], [time_1-time, time_2-time], [T1, is, the, same, date, as, T2]). % see reasoner.pl before/2
predef_dict([between,Minimum,Maximum,Middle], [min-date, max-date, middle-date], 
                [Middle, is, between, Minimum, &, Maximum]).
predef_dict([is_1_day_after, A, B], [date-date, second_date-date],
                [A, is, '1', day, after, B]).
predef_dict([is_days_after, A, B, C], [date-date, number-number, second_date-date],
                  [A, is, B, days, after, C]).
predef_dict([immediately_before, T1, T2], [time_1-time, time_2-time], [T1, is, immediately, before, T2]). % see reasoner.pl before/2
predef_dict([\=, T1, T2], [thing_1-thing, thing_2-thing], [T1, is, different, from, T2]).
predef_dict([==, T1, T2], [thing_1-thing, thing_2-thing], [T1, is, equivalent, to, T2]).
predef_dict([is_a, Object, Type], [object-object, type-type], [Object, is, of, type, Type]).
predef_dict([is_not_before, T1, T2], [time1-time, time2-time], [T1, is, not, before, T2]). % see reasoner.pl before/2
predef_dict([=, T1, T2], [thing_1-thing, thing_2-thing], [T1, is, equal, to, T2]).
predef_dict([isbefore, T1, T2], [time1-time, time2-time], [T1, is, before, T2]). % see reasoner.pl before/2
predef_dict([isafter, T1, T2], [time1-time, time2-time], [T1, is, after, T2]).  % see reasoner.pl before/2
predef_dict([member, Member, List], [member-object, list-list], [Member, is, in, List]).
predef_dict([is, A, B], [term-term, expression-expression], [A, is, B]). % builtin Prolog assignment
% predefined entries:
%predef_dict([assert,Information], [info-clause], [this, information, Information, ' has', been, recorded]).
predef_dict([\=@=, T1, T2], [thing_1-thing, thing_2-thing], [T1, \,=,@,=, T2]).
predef_dict([\==, T1, T2], [thing_1-thing, thing_2-thing], [T1, \,=,=, T2]).
predef_dict([=\=, T1, T2], [thing_1-thing, thing_2-thing], [T1, =,\,=, T2]).
predef_dict([=@=, T1, T2], [thing_1-thing, thing_2-thing], [T1, =,@,=, T2]).
predef_dict([==, T1, T2], [thing_1-thing, thing_2-thing], [T1, =,=, T2]).
predef_dict([=<, T1, T2], [thing_1-thing, thing_2-thing], [T1, =,<, T2]).
predef_dict([=<, T1, T2], [thing_1-thing, thing_2-thing], [T1, =,<, T2]).
predef_dict([>=, T1, T2], [thing_1-thing, thing_2-thing], [T1, >,=, T2]).
predef_dict([=, T1, T2], [thing_1-thing, thing_2-thing], [T1, =, T2]).
predef_dict([<, T1, T2], [thing_1-thing, thing_2-thing], [T1, <, T2]).
predef_dict([>, T1, T2], [thing_1-thing, thing_2-thing], [T1, >, T2]).
predef_dict([unparse_time, Secs, Date], [secs-time, date-date], [Secs, corresponds, to, date, Date]).
predef_dict([must_be, Type, Term], [type-type, term-term], [Term, must, be, Type]).
predef_dict([must_not_be, A, B], [term-term, variable-variable], [A, must, not, be, B]). 

% pre_is_type/1
pre_is_type(thing).
pre_is_type(time).
pre_is_type(type).
pre_is_type(object).
pre_is_type(date).
pre_is_type(day).
pre_is_type(person).
pre_is_type(list). 
pre_is_type(number). 

% support predicates
must_be(A, var) :- var(A).
must_be(A, nonvar) :- nonvar(A).
must_be_nonvar(A) :- nonvar(A).
must_not_be(A,B) :- not(must_be(A,B)). 

has_as_head_before([B|C], B, C). 

% see reasoner.pl
%before(A,B) :- nonvar(A), nonvar(B), number(A), number(B), A < B. 

/* ---------------------------------------------------------------  meta predicates CLI */

is_it_illegal(English, Scenario) :- % only event as possibly illegal for the time being
    (parsed -> true; fail), !, 
    translate_query(English, happens(Goal, T)), % later -->, Kbs),
    %print_message(informational, "Goal Name: ~w"-[GoalName]),
    pengine_self(SwishModule), %SwishModule:query(GoalName, Goal), 
    %extract_goal_command(Question, SwishModule, Goal, Command), 
    copy_term(Goal, CopyOfGoal), 
    translate_goal_into_LE(CopyOfGoal, RawGoal),  name_as_atom(RawGoal, EnglishQuestion), 
    print_message(informational, "Testing illegality: ~w"-[EnglishQuestion]),
    print_message(informational, "Scenario: ~w"-[Scenario]),
    get_assumptions_from_scenario(Scenario, SwishModule, Assumptions), 
    setup_call_catcher_cleanup(assert_facts(SwishModule, Assumptions), 
            %catch(SwishModule:holds(Goal), Error, ( print_message(error, Error), fail ) ), 
            %catch(Command, Error, ( print_message(error, Error), fail ) ), 
            catch(SwishModule:it_is_illegal(Goal, T), Error, ( print_message(error, Error), fail ) ), 
            _Result, 
            retract_facts(SwishModule, Assumptions)), 
    translate_goal_into_LE(Goal, RawAnswer), name_as_atom(RawAnswer, EnglishAnswer),  
    print_message(informational, "Answers: ~w"-[EnglishAnswer]).

% extract_goal_command(WrappedGoal, Module, InnerGoal, RealGoal)
extract_goal_command(Goal, M, InnerGoal, Command) :- nonvar(Goal), 
    extract_goal_command_(Goal, M, InnerGoal, Command). 

extract_goal_command_((A;B), M, (IA;IB), (CA;CB)) :-
    extract_goal_command_(A, M, IA, CA), extract_goal_command_(B, M, IB, CB), !. 
extract_goal_command_((A,B), M, (IA,IB), (CA,CB)) :-
    extract_goal_command_(A, M, IA, CA), extract_goal_command_(B, M, IB, CB), !. 
extract_goal_command_(holds(Goal,T), M, Goal, (holds(Goal,T);M:holds(Goal,T))) :- !.
extract_goal_command_(happens(Goal,T), M, Goal, (happens(Goal,T);M:happens(Goal,T))) :- !.
extract_goal_command_(Goal, M, Goal, M:Goal) :- !. 

get_assumptions_from_scenario(noscenario, _, []) :- !.  
get_assumptions_from_scenario(Scenario, SwishModule, Assumptions) :-
    SwishModule:example(Scenario, [scenario(Assumptions, _)]), !.

translate_query(English_String, Goals) :-
    tokenize(English_String, Tokens, [cased(true), spaces(true), numbers(false)]),
    unpack_tokens(Tokens, UTokens), 
    clean_comments(UTokens, CTokens), 
    phrase(conditions(0, [], _, Goals), CTokens) -> true 
    ; ( error_notice(error, Me,Pos, ContextTokens), print_message(error, [Me,Pos,ContextTokens]), fail ). 

/* ----------------------------------------------------------------- Event Calculus  */
% holds/2
holds(Fluent, T) :-
    pengine_self(SwishModule), %trace, 
    SwishModule:happens(Event, T1), 
    rbefore(T1,T),  
    SwishModule:initiates(Event, Fluent, T1), 
    %(nonvar(T) -> rbefore(T1,T); T=(after(T1)-_)),  % T1 is strictly before T 'cos T is not a variable
    %(nonvar(T) -> rbefore(T1,T); true),
    not(interrupted(T1, Fluent, T)).

rbefore(T1, T) :-
    nonvar(T1), nonvar(T), isbefore(T1, T). %, !.
%rbefore(T1, T) :- (var(T1); var(T)), !. % if anyone is a variable, don't compute
%rbefore(T1, (after(T2)-_)) :-
%    nonvar(T1), nonvar(T2), before(T1, T2).

% interrupted/3
interrupted(T1, Fluent, T2) :- %trace, 
    pengine_self(SwishModule),
    SwishModule:happens(Event, T), 
    rbefore(T, T2), 
    SwishModule:terminates(Event, Fluent, T), 
    (rbefore(T1, T); T1=T), !.
    %(nonvar(T2) -> rbefore(T, T2) ; true ), !.  
    %(T2=(after(T1)-_)->T2=(after(T1)-before(T)); rbefore(T,T2)). 

/* ----------------------------------------------------------------- CLI English */
% answer/1
% answer(+Query or Query Expression)
answer(English) :- %trace, 
    answer(English, empty). 
    % parsed, 
    % pengine_self(SwishModule), 
    % (translate_command(SwishModule, English, GoalName, Goal, Scenario) -> true 
    % ; ( print_message(error, "Don't understand this question: ~w "-[English]), !, fail ) ), % later -->, Kbs),
    % copy_term(Goal, CopyOfGoal),  
    % translate_goal_into_LE(CopyOfGoal, RawGoal), name_as_atom(RawGoal, EnglishQuestion), 
    % print_message(informational, "Query ~w with ~w: ~w"-[GoalName, Scenario, EnglishQuestion]),
    % %print_message(informational, "Scenario: ~w"-[Scenario]),
    % % assert facts in scenario
    % (Scenario==noscenario -> Facts = [] ; 
    %     (SwishModule:example(Scenario, [scenario(Facts, _)]) -> 
    %         true;  print_message(error, "Scenario: ~w does not exist"-[Scenario]))), !,  
    % %print_message(informational, "Facts: ~w"-[Facts]), 
    % extract_goal_command(Goal, SwishModule, _InnerGoal, Command), 
    % %print_message(informational, "Command: ~w"-[Command]),
    % setup_call_catcher_cleanup(assert_facts(SwishModule, Facts), 
    %         catch((true, Command), Error, ( print_message(error, Error), fail ) ), 
    %         _Result, 
    %         retract_facts(SwishModule, Facts)), 
    % translate_goal_into_LE(Goal, RawAnswer), name_as_atom(RawAnswer, EnglishAnswer),  
    % print_message(informational, "Answer: ~w"-[EnglishAnswer]).

% answer/2
% answer(+Query, with(+Scenario))
answer(English, Arg) :- trace, 
    parsed,
    prepare_query(English, Arg, SwishModule, Goal, Facts, Command), 
    setup_call_catcher_cleanup(assert_facts(SwishModule, Facts), 
            Command, 
            %call(Command), 
            %catch_with_backtrace(Command, Error, print_message(error, Error)), 
            %catch((true, Command), Error, ( print_message(error, Error), fail ) ), 
            _Result, 
            retract_facts(SwishModule, Facts)), 
    show_answer(Goal). 

% answer/3
% answer(+English, with(+Scenario), -Result)
answer(English, Arg, EnglishAnswer) :- 
    parsed, 
    pengine_self(SwishModule), 
    translate_command(SwishModule, English, _, Goal, PreScenario), % later -->, Kbs),
    %copy_term(Goal, CopyOfGoal), 
    %translate_goal_into_LE(CopyOfGoal, RawGoal), name_as_atom(RawGoal, EnglishQuestion), 
    ((Arg = with(ScenarioName), PreScenario=noscenario) -> Scenario=ScenarioName; Scenario=PreScenario), 
    extract_goal_command(Goal, SwishModule, _InnerGoal, Command),
    (Scenario==noscenario -> Facts = [] ; SwishModule:example(Scenario, [scenario(Facts, _)])), 
    setup_call_catcher_cleanup(assert_facts(SwishModule, Facts), 
            catch_with_backtrace(Command, Error, print_message(error, Error)), 
            %catch(Command, Error, ( print_message(error, Error), fail ) ), 
            _Result, 
            retract_facts(SwishModule, Facts)),
    translate_goal_into_LE(Goal, RawAnswer), name_as_atom(RawAnswer, EnglishAnswer). 
    %reasoner:query_once_with_facts(Goal,Scenario,_,_E,Result).

% answer/4
% answer(+English, with(+Scenario), -Explanations, -Result) :-
% answer(at(English, Module), Arg, E, Result) :- trace,
answer(English, Arg, E, Result) :- %trace, 
    parsed, myDeclaredModule(Module), 
    pengine_self(SwishModule), 
    translate_command(SwishModule, English, _, Goal, PreScenario), 
    ((Arg = with(ScenarioName), PreScenario=noscenario) -> Scenario=ScenarioName; Scenario=PreScenario), 
    extract_goal_command(Goal, SwishModule, InnerGoal, _Command),
    (Scenario==noscenario -> Facts = [] ; SwishModule:example(Scenario, [scenario(Facts, _)])), !, 
    setup_call_catcher_cleanup(assert_facts(SwishModule, Facts), 
            catch((true, query(at(InnerGoal, Module),_,E,Result)), Error, ( print_message(error, Error), fail ) ), 
            _Result, 
            retract_facts(SwishModule, Facts)). 

% prepare_query/6
% prepare_query(English, Arguments, Module, Goal, Facts, Command)
prepare_query(English, Arg, SwishModule, Goal, Facts, Command) :- %trace, 
    %restore_dicts, 
    pengine_self(SwishModule), 
    (translate_command(SwishModule, English, GoalName, Goal, PreScenario) -> true 
    ; ( print_message(error, "Don't understand this question: ~w "-[English]), !, fail ) ), % later -->, Kbs),
    copy_term(Goal, CopyOfGoal),  
    translate_goal_into_LE(CopyOfGoal, RawGoal), name_as_atom(RawGoal, EnglishQuestion), 
    ((Arg = with(ScenarioName), PreScenario=noscenario) -> Scenario=ScenarioName; Scenario=PreScenario),
    show_question(GoalName, Scenario, EnglishQuestion), 
    %print_message(informational, "Scenario: ~w"-[Scenario]),
    (Scenario==noscenario -> Facts = [] ; 
        (SwishModule:example(Scenario, [scenario(Facts, _)]) -> 
            true;  print_message(error, "Scenario: ~w does not exist"-[Scenario]))),
    %print_message(informational, "Facts: ~w"-[Facts]), 
    extract_goal_command(Goal, SwishModule, _InnerGoal, Command), !.  
    %print_message(informational, "Command: ~w"-[Command]). 

show_question(GoalName, Scenario, NLQuestion) :-   
    (source_lang(en) -> print_message(informational, "Query ~w with ~w: ~w"-[GoalName, Scenario, NLQuestion]); true),
    (source_lang(fr) -> print_message(informational, "La question ~w avec ~w: ~w"-[GoalName, Scenario, NLQuestion]); true),
    (source_lang(it) -> print_message(informational, "Il interrogativo ~w con ~w: ~w"-[GoalName, Scenario, NLQuestion]); true),  
    !.  

show_answer(Goal) :-
    translate_goal_into_LE(Goal, RawAnswer), name_as_atom(RawAnswer, NLAnswer), 
    (source_lang(en) -> print_message(informational, "Answer: ~w"-[NLAnswer]); true), 
    (source_lang(fr) -> print_message(informational, "La réponse: ~w"-[NLAnswer]); true), 
    (source_lang(it) -> print_message(informational, "Il responso: ~w"-[NLAnswer]); true), 
    !. 

% translate_goal_into_LE/2
% translate_goal_into_LE(+Goals_after_being_queried, -Goals_translated_into_LEnglish_as_answers)
translate_goal_into_LE((G,R), WholeAnswer) :- 
    translate_goal_into_LE(G, Answer), 
    translate_goal_into_LE(R, RestAnswers), !, 
    append(Answer, ['\n','\t',and|RestAnswers], WholeAnswer).
translate_goal_into_LE(not(G), [it,is,not,the,case,that,'\n', '\t'|Answer]) :- 
    translate_goal_into_LE(G, Answer), !.
translate_goal_into_LE(Goal, ProcessedWordsAnswers) :-  
    Goal =.. [Pred|GoalElements], meta_dictionary([Pred|GoalElements], Types, WordsAnswer),
    process_types_or_names(WordsAnswer, GoalElements, Types, ProcessedWordsAnswers), !. 
translate_goal_into_LE(Goal, ProcessedWordsAnswers) :-  
    Goal =.. [Pred|GoalElements], dictionary([Pred|GoalElements], Types, WordsAnswer),
    %print_message(informational, "from  ~w to ~w "-[Goal, ProcessedWordsAnswers]), 
    process_types_or_names(WordsAnswer, GoalElements, Types, ProcessedWordsAnswers), !.
translate_goal_into_LE(happens(Goal,T), Answer) :-    % simple goals do not return a list, just a literal
    Goal =.. [Pred|GoalElements], dictionary([Pred|GoalElements], Types, WordsAnswer), 
    process_types_or_names(WordsAnswer, GoalElements, Types, ProcessedWordsAnswers), 
    process_time_term(T, TimeExplain), !, 
    Answer = ['At', TimeExplain, it, occurs, that|ProcessedWordsAnswers].
translate_goal_into_LE(holds(Goal,T), Answer) :- 
    Goal =.. [Pred|GoalElements], dictionary([Pred|GoalElements], Types, WordsAnswer), 
    process_types_or_names(WordsAnswer, GoalElements, Types, ProcessedWordsAnswers), 
    process_time_term(T, TimeExplain),
    Answer = ['At', TimeExplain, it, holds, that|ProcessedWordsAnswers], !. 

process_time_term(T,ExplainT) :- var(T), name_as_atom([a, time, T], ExplainT). % in case of vars
process_time_term(T,T) :- nonvar(T), atom(T), !. 
process_time_term(T,Time) :- nonvar(T), number(T), T>100, unparse_time(T, Time), !.  
process_time_term(T,Time) :- nonvar(T), number(T), T=<100, T=Time, !.  % hack to avoid standard time transformation
process_time_term((after(T)-Var), Explain) :- var(Var), !,
    process_time_term(T, Time), 
    name_as_atom([any, time, after, Time], Explain).
process_time_term((after(T1)-before(T2)), Explain) :- !,
    process_time_term(T1, Time1), process_time_term(T2, Time2),
    name_as_atom([any, time, after, Time1, and, before, Time2], Explain).

% process_types_or_names/4
process_types_or_names([], _, _, []) :- !.
process_types_or_names([Word|RestWords], Elements, Types, PrintExpression ) :- 
    atom(Word), concat_atom(WordList, '_', Word), !, 
    process_types_or_names(RestWords,  Elements, Types, RestPrintWords),
    append(WordList, RestPrintWords, PrintExpression).
process_types_or_names([Word|RestWords], Elements, Types, PrintExpression ) :- 
    var(Word), matches_name(Word, Elements, Types, Name), !, 
    process_types_or_names(RestWords,  Elements, Types, RestPrintWords),
    tokenize_atom(Name, NameWords), delete_underscore(NameWords, CNameWords),
    add_determiner(CNameWords, PrintName), append(['*'|PrintName], ['*'|RestPrintWords], PrintExpression).
process_types_or_names([Word|RestWords], Elements, Types, [PrintWord|RestPrintWords] ) :- 
    matches_type(Word, Elements, Types, date), 
    ((nonvar(Word), number(Word)) -> unparse_time(Word, PrintWord); PrintWord = Word), !, 
    process_types_or_names(RestWords,  Elements, Types, RestPrintWords). 
process_types_or_names([Word|RestWords], Elements, Types, [PrintWord|RestPrintWords] ) :- 
    matches_type(Word, Elements, Types, day), 
    ((nonvar(Word), number(Word)) -> unparse_time(Word, PrintWord); PrintWord = Word), !, 
    process_types_or_names(RestWords,  Elements, Types, RestPrintWords). 
process_types_or_names([Word|RestWords],  Elements, Types, Output) :-
    compound(Word), 
    translate_goal_into_LE(Word, PrintWord), !, % cut the alternatives
    process_types_or_names(RestWords,  Elements, Types, RestPrintWords),
    append(PrintWord, RestPrintWords, Output). 
process_types_or_names([Word|RestWords],  Elements, Types, [Word|RestPrintWords] ) :-
    process_types_or_names(RestWords,  Elements, Types, RestPrintWords).

%process_template_for_scasp/4
%process_template_for_scasp(WordsAnswer, GoalElements, Types, +FormatElements, +ProcessedWordsAnswers)
process_template_for_scasp([], _, _, [], []) :- !.
process_template_for_scasp([Word|RestWords], Elements, Types, [' @(~w:~w) '|RestFormat], [Word, TypeName|RestPrintWords]) :- 
    var(Word), matches_type(Word, Elements, Types, Type), !, 
    process_template_for_scasp(RestWords,  Elements, Types, RestFormat, RestPrintWords),
    tokenize_atom(Type, NameWords), delete_underscore(NameWords, [TypeName]).
process_template_for_scasp([Word|RestWords],  Elements, Types, ['~w'|RestFormat], [Word|RestPrintWords] ) :-
    op_stop(List), member(Word,List), !, 
    process_template_for_scasp(RestWords,  Elements, Types, RestFormat, RestPrintWords).
process_template_for_scasp([Word|RestWords],  Elements, Types, [' ~w '|RestFormat], [Word|RestPrintWords] ) :-
    process_template_for_scasp(RestWords,  Elements, Types, RestFormat, RestPrintWords).

add_determiner([Word|RestWords], [Det, Word|RestWords]) :-
    name(Word,[First|_]), proper_det(First, Det).

delete_underscore([], []) :- !. 
delete_underscore(['_'|Rest], Final) :- delete_underscore(Rest, Final), !.  
delete_underscore([W|Rest], [W|Final]) :- delete_underscore(Rest, Final). 

proper_det(97, an) :- !.
proper_det(101, an) :- !.
proper_det(105, an) :- !.
proper_det(111, an) :- !.
proper_det(117, an) :- !.
proper_det(_, a). 

matches_name(Word, [Element|_], [Name-_|_], Name) :- Word == Element, !.
matches_name(Word, [_|RestElem], [_|RestTypes], Name) :-
    matches_name(Word, RestElem, RestTypes, Name). 

matches_type(Word, [Element|_], [_-Type|_], Type) :- Word == Element, !.
matches_type(Word, [_|RestElem], [_|RestTypes], Type) :-
    matches_type(Word, RestElem, RestTypes, Type). 

assert_facts(_, []) :- !. 
assert_facts(SwishModule, [F|R]) :- nonvar(F), % print_message(informational, "asserting: ~w"-[SwishModule:F]),
    assertz(SwishModule:F), assert_facts(SwishModule, R).

retract_facts(_, []) :- !. 
retract_facts(SwishModule, [F|R]) :- nonvar(F), % print_message(informational, "retracting: ~w"-[SwishModule:F]),
    retract(SwishModule:F), retract_facts(SwishModule, R). 

% translate_command/1
translate_command(SwishModule, English_String, GoalName, Goals, Scenario) :- %trace, 
    tokenize(English_String, Tokens, [cased(true), spaces(true), numbers(false)]),
    unpack_tokens(Tokens, UTokens), 
    clean_comments(UTokens, CTokens),
    phrase(command_(GoalName, Scenario), CTokens),
    ( SwishModule:query(GoalName, Goals) -> true; (print_message(informational, "No goal named: ~w"-[GoalName]), fail) ), !. 

translate_command(_, English_String, GoalName, Goals, Scenario) :-
    tokenize(English_String, Tokens, [cased(true), spaces(true), numbers(false)]),
    unpack_tokens(Tokens, UTokens), 
    clean_comments(UTokens, CTokens), Scenario=noscenario, GoalName=nonamed, 
    (phrase(conditions(0, [], _, Goals), CTokens) ->  true  ;
        ( once(error_notice(error, Me,_, ContextTokens)), print_message(informational, "~w ~w"-[Me,ContextTokens]), CTokens=[], fail )
    ). 

command_(Goal, Scenario) --> 
    %order_, goal_(Goal), with_, scenario_name_(Scenario). 
    goal_(Goal), with_, scenario_name_(Scenario).
command_(Goal, noscenario) --> 
    goal_(Goal).

%order_ --> [answer], spaces(_).
%order_ --> [run], spaces(_).
%order_ --> [solve], spaces(_).
%order_ --> [resolve], spaces(_).

goal_(Goal) --> query_or_empty, extract_constant([with], GoalWords), spaces(_), 
    {name_as_atom(GoalWords, Goal)}. % goal by name

query_or_empty --> query_.
query_or_empty --> []. 

with_ --> [with], spaces(_).

scenario_name_(Scenario) -->  scenario_or_empty_, extract_constant([], ScenarioWords), spaces(_), 
{name_as_atom(ScenarioWords, Scenario)}. % Scenario by name

scenario_or_empty_ --> [scenario], spaces(_). 
scenario_or_empty_ --> spaces(_). 
 
% show/1
show(prolog) :-
    show(metarules), 
    show(rules),
    show(queries),
    show(scenarios). 

show(rules) :- % trace, 
    pengine_self(SwishModule), 
    findall((Pred :- Body), 
        (dict(PredicateElements, _, _), Pred=..PredicateElements, clause(SwishModule:Pred, Body_), unwrapBody(Body_, Body)), Predicates),
    forall(member(Clause, Predicates), portray_clause(Clause)).

% 
%(op2tokens(Pred, _, OpTokens) -> % Fixing binary predicates for scasp
%( append([X|_], [Y], GoalElements),
%  append([X|OpTokens],[Y], RevGoalElements), 
%  print_message(informational, "binary op ~w"-[Pred]) ) 
%; RevGoalElements = GoalElements 
%), 

show(metarules) :- % trace, 
    pengine_self(SwishModule), 
    findall((Pred :- Body), 
        (meta_dict(PredicateElements, _, _), Pred=..PredicateElements, clause(SwishModule:Pred, Body_), unwrapBody(Body_, Body)), Predicates),
    forall(member(Clause, Predicates), portray_clause(Clause)).

show(queries) :- % trace, 
    pengine_self(SwishModule), 
    findall((query(A,B) :- true), 
        (clause(SwishModule:query(A,B), _)), Predicates),
    forall(member(Clause, Predicates), portray_clause(Clause)).

show(scenarios) :- % trace, 
    pengine_self(SwishModule), 
    findall((example(A,B) :- true), 
        (clause(SwishModule:example(A,B), _)), Predicates),
    forall(member(Clause, Predicates), portray_clause(Clause)).

show(templates) :-
    findall(EnglishAnswer, 
        ( ( meta_dictionary([_|GoalElements], Types, WordsAnswer) ; 
            dictionary([_|GoalElements], Types, WordsAnswer)),
        process_types_or_names(WordsAnswer, GoalElements, Types, ProcessedWordsAnswers),
        name_as_atom(ProcessedWordsAnswers, EnglishAnswer)), Templates), 
    forall(member(T, Templates), print_message(informational, "~w"-[T])). 

show(templates_scasp) :-
    findall(Term, 
        ( ( meta_dict([Pred|GoalElements], Types, WordsAnswer) ;
            dict([Pred|GoalElements], Types, WordsAnswer)),
        Goal =.. [Pred|GoalElements],
        process_template_for_scasp(WordsAnswer, GoalElements, Types, FormatEl, LE),
        atomic_list_concat(['#pred ~w ::\''|FormatEl], Format),
        Elements = [Goal|LE],
        numbervars(Elements, 1, _),
        format(atom(Term), Format, Elements)), Templates),
    forall(member(T, Templates), (atom_string(T, R), print_message(informational, '~w\'.'-[R]))).

show(types) :-
    %findall(EnglishAnswer, 
    %    ( dictionary([_|GoalElements], Types, _), 
    %      member((Name-Type), Types), 
    %    process_types_or_names([Type], GoalElements, Types, ProcessedWordsAnswers),
    %    name_as_atom(ProcessedWordsAnswers, EnglishAnswer)), Templates), 
    print_message(information, "Pre-defined Types:"-[]),
    setof(Tpy, pre_is_type(Tpy), PreSet), 
    forall(member(Tp, PreSet),print_message(informational, '~a'-[Tp])), 
    print_message(informational, "Types defined in the current document:"-[]), 
    setof(Ty, is_type(Ty), Set), 
    forall(member(T, Set), print_message(informational, '~a'-[T])). 

show(scasp) :-
    show(templates_scasp), 
    show(metarules), 
    show(rules). 

show(scasp, with(Q, S)) :-
    show(scasp), 
    pengine_self(SwishModule), 
    clause(SwishModule:query(Q,Query), _),
    clause(SwishModule:example(S, [scenario(Scenario, _)]), _),
    %print_message(informational, "% scenario ~w ."-[List]),
    forall(member(Clause, Scenario), portray_clause(Clause)),
    print_message(informational, "/** <examples>\n?- ? ~w .\n**/"-[Query]).

show(scasp, with(Q)) :-
    show(scasp), 
    pengine_self(SwishModule), 
    clause(SwishModule:query(Q,Query), _),
    print_message(informational, "/** <examples>\n?- ? ~w .\n**/"-[Query]).

unwrapBody(targetBody(Body, _, _, _, _, _), Body). 
%unwrapBody(Body, Body). 

% hack to bring in the reasoner for explanations.  
targetBody(G, false, _, '', [], _) :- %trace, 
    %nonvar(G),
    pengine_self(SwishModule), extract_goal_command(G, SwishModule, _InnerG, Command), % clean extract goals
    %print_message(informational, "Trying ~w"-[Command]), 
    %call(Command). 
    call(Command). 
    %Command.
    %catch_with_backtrace(Command, Error, (print_message(error, Error))). 

dump(templates, String) :-
    findall(local_dict(Prolog, NamesTypes, Templates), (dict(Prolog, NamesTypes, Templates)), PredicatesDict),
    with_output_to(string(String01), forall(member(Clause1, PredicatesDict), portray_clause(Clause1))),
    (PredicatesDict==[]-> string_concat("local_dict([],[],[]).\n", String01, String1); String1 = String01), 
    findall(local_meta_dict(Prolog, NamesTypes, Templates), (meta_dict(Prolog, NamesTypes, Templates)), PredicatesMeta),
    with_output_to(string(String02), forall(member(Clause2, PredicatesMeta), portray_clause(Clause2))),
    (PredicatesMeta==[]-> string_concat("local_meta_dict([],[],[]).\n", String02, String2); String2 = String02), 
    string_concat(String1, String2, String).     

dump(all, Module, List, String) :-
	dump(templates, StringTemplates), 
	dump(rules, List, StringRules),
    dump(scenarios, List, StringScenarios),
    dump(queries, List, StringQueries), 
    string_concat(":-module(\'", Module, Module01),
    string_concat(Module01, "\', []).\n", TopHeadString), 
	string_concat(TopHeadString, StringTemplates, HeadString), 
	string_concat(HeadString, StringRules, String1),
    string_concat(String1, StringScenarios, String2),
    string_concat(String2, StringQueries, String3), 
    string_concat(String3, "prolog_le(verified).\n", String).   

dump(rules, List, String) :- %trace, 
    findall((Pred :- Body), 
        (member( (Pred :- Body_), List), unwrapBody(Body_, Body)), Predicates),
    with_output_to(string(String), forall(member(Clause, Predicates), portray_clause(Clause))).

dump(queries, List, String) :- 
    findall( query(Name, Query), 
        (member( query(Name, Query), List)), Predicates),
    with_output_to(string(String), forall(member(Clause, Predicates), portray_clause(Clause))).

dump(scenarios, List, String) :- 
    findall( example(Name, Scenario), 
        (member( example(Name, Scenario), List)), Predicates),
    with_output_to(string(String), forall(member(Clause, Predicates), portray_clause(Clause))).

restore_dicts :- %trace, 
    %print_message(informational, "dictionaries being restored"),
    pengine_self(SwishModule),
    (SwishModule:local_dict(_,_,_) -> findall(dict(A,B,C), SwishModule:local_dict(A,B,C), ListDict) ; ListDict = []),
    (SwishModule:local_meta_dict(_,_,_) -> findall(meta_dict(A,B,C), SwishModule:local_meta_dict(A,B,C), ListMetaDict); ListMetaDict = []),
    append(ListDict, ListMetaDict, DictEntries), 
    %print_message(informational, "the dictionaries being restored are ~w"-[DictEntries]),
    collect_all_preds(SwishModule, Preds),
    declare_preds_as_dynamic(SwishModule, Preds), 
    order_templates(DictEntries, OrderedEntries), 
    process_types_dict(OrderedEntries, Types), 
    append(OrderedEntries, Types, MRules), 
    assertall(MRules), !. % asserting contextual information

collect_all_preds(M, ListPreds) :-
    findall(AA, ((M:local_dict(A,_,_); M:local_meta_dict(A, _,_)), A\=[], AA =.. A, not(clause(M:AA,_))), ListPreds). 

declare_preds_as_dynamic(_, []) :- !. 
declare_preds_as_dynamic(M, [F|R]) :- functor(F, P, A),  % facts are the templates now
        dynamic([M:P/A], [thread(local), discontiguous(true)]), declare_preds_as_dynamic(M, R). 

%%% ------------------------------------------------ Swish Interface to logical english
%% based on logicalcontracts' lc_server.pl

:- multifile prolog_colour:term_colours/2.
prolog_colour:term_colours(en(_Text),lps_delimiter-[classify]). % let 'en' stand out with other taxlog keywords
prolog_colour:term_colours(en_decl(_Text),lps_delimiter-[classify]). % let 'en_decl' stand out with other taxlog keywords


user:(answer Query with Scenario):- 
    answer(Query,with(Scenario)). 
user: (répondre Query avec Scenario):-
    answer(Query,with(Scenario)).
user: (risposta Query con Scenario):-
    answer(Query,with(Scenario)). 
%:- discontiguous (with)/2.
%user:(Query with Scenario):-  
%    answer(Query,with(Scenario)). 
%user:(Command1 and Command2) :-
%    call(Command1), call(Command2). 
user:answer( EnText) :- answer( EnText).
user:answer( EnText, Scenario) :- answer( EnText, Scenario).
user:answer( EnText, Scenario, Result) :- answer( EnText, Scenario, Result).
user:answer( EnText, Scenario, E, Result) :- answer( EnText, Scenario, E, Result).

user:(show Something) :- 
    show(Something). 

user:(show(Something, With) ):- 
    show(Something, With). 

user:is_it_illegal( EnText, Scenario) :- is_it_illegal( EnText, Scenario).

user:query(Name, Goal) :- query(Name, Goal).

user:holds(Fluent, Time) :- holds(Fluent, Time). 

user:has_as_head_before(List, Head, Rest) :- has_as_head_before(List, Head, Rest). 

% for term_expansion
%user:le_taxlog_translate( en(Text), Terms) :- le_taxlog_translate( en(Text), Terms)..
%user:le_taxlog_translate( en(Text), File, Base, Terms) :- le_taxlog_translate( en(Text),  File, Base, Terms).

user:op_stop(StopWords) :- op_stop(StopWords). 

user:targetBody(G, B, X, S, L, R) :- targetBody(G, B, X, S, L, R). 

user:restore_dicts :- restore_dicts.

%le_taxlog_translate( EnText, Terms) :- le_taxlog_translate( EnText, someFile, 1, Terms).

% Baseline is the line number of the start of Logical English text
le_taxlog_translate( en(Text), File, BaseLine, Terms) :-
    text_to_logic(Text, Terms) -> true; showErrors(File,BaseLine). 
le_taxlog_translate( fr(Text), File, BaseLine, Terms) :-
    text_to_logic(Text, Terms) -> true; showErrors(File,BaseLine). 
le_taxlog_translate( it(Text), File, BaseLine, Terms) :-
        text_to_logic(Text, Terms) -> true; showErrors(File,BaseLine). 
le_taxlog_translate( prolog_le(verified), _, _, prolog_le(verified)) :- %trace, 
    assertz(parsed), 
    restore_dicts. 

combine_list_into_string(List, String) :-
    combine_list_into_string(List, "", String).

combine_list_into_string([], String, String).
combine_list_into_string([HS|RestS], Previous, OutS) :-
    string_concat(Previous, HS, NewS),
    combine_list_into_string(RestS, NewS, OutS).

user:showtaxlog :- showtaxlog.
user:is_type(T) :- is_type(T).
user:dict(A,B,C) :- dict(A,B,C).
user:meta_dict(A,B,C) :- meta_dict(A,B,C). 

showtaxlog:-
    % ?????????????????????????????????????????
	% psyntax:lps_swish_clause(en(Text),Body,_Vars),
	once(text_to_logic(_,Taxlog)),
    showErrors(someFile,0), 
	writeln(Taxlog),
	fail.
showtaxlog.

sanbox:safe_primitive(le_input:is_type(_)).
sanbox:safe_primitive(le_input:dict(_,_,_)).
sanbox:safe_primitive(le_input:meta_dict(_,_,_)).
sandbox:safe_primitive(le_input:showtaxlog).
sandbox:safe_primitive(le_input:restore_dicts).
sandbox:safe_primitive(le_input:answer( _EnText)).
sandbox:safe_primitive(le_input:show( _Something)).
sandbox:safe_primitive(le_input:show( _Something, _With)).
sandbox:safe_primitive(le_input:answer( _EnText, _Scenario)).
sandbox:safe_primitive(le_input:answer( _EnText, _Scenario, _Result)).
sandbox:safe_primitive(le_input:answer( _EnText, _Scenario, _Explanation, _Result)).
sandbox:safe_primitive(le_input:le_taxlog_translate( _EnText, _File, _Baseline, _Terms)). 
