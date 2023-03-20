# B2Evolution to Ghost migration script

In this repo you can find a script that generates a JSON file with all the
posts you have in your B2Evolution MySQL database instance.

It connects directly to the database and generates the JSON structure on
standard output. The file can be piped to a file and directly imported into
a Ghost instance using the Settings / Labs / Import content feature.

## Installation

This is a simple Perl script, and requires some CPAN dependencies. The
dependencies are all listed in the cpanfile, and can usually be installed
either through your package manager (if you're using system perl), or using
the command `cpanm --installdeps .` if your using a custom perl instance.

If you use a custom perl and install directly from CPAN, make sure the
`mysql_config` program is installed (needed by DBD::mysql). It can usually
be installed with your system package manager. In Debian-based distros, it
is named `libmysqlclient-dev`.

## Usage

Fill in your database details in `.env`, using `.env.template` as a guide,
or set the environment variables in some other way. Make sure you know which
timezone has been used for all the timestamps in the b2evolution database,
as it doesn't use database timestamp fields with timezone information. Also
fill in this information in `.env`. If you don't set this, the script
defaults to `UTC`.

## License

This script is licensed with the same terms as Perl itself.

## Copyright

Robin Smidsrød (robin@smidsrod.no)
