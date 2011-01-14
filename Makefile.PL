use inc::Module::Install;

name "github-growler";
all_from "github-growler.pl";
install_script "github-growler.pl";

requires 'Config::IniFiles';
requires 'LWP::Simple';
requires 'URI';
requires 'Web::Scraper';
requires 'XML::LibXML';
requires 'Cocoa::Growl';
requires 'Cocoa::EventLoop';

WriteAll;
