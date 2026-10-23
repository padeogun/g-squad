import type * as React from 'react';

export type IconName = 'lock' | 'alert' | 'info' | 'check' | 'calendar' | 'users' | 'list' | 'plus' | 'close' | 'download' | 'more' | 'clock' | 'mail' | 'pin';
export interface IconProps { name: IconName; size?: number; label?: string; className?: string }
export declare function Icon(props: IconProps): React.ReactElement;

export interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> { variant?: 'primary' | 'secondary' | 'lime' | 'quiet'; size?: 'md' | 'sm'; icon?: IconName; href?: string }
export declare function Button(props: ButtonProps): React.ReactElement;

export interface ChipProps { tone?: 'ok' | 'warn' | 'danger' | 'info' | 'neutral' | 'app'; icon?: IconName; children?: React.ReactNode; className?: string }
export declare function Chip(props: ChipProps): React.ReactElement;

export interface NoticeProps { tone?: 'info' | 'warn' | 'danger' | 'ok'; title?: string; children?: React.ReactNode }
export declare function Notice(props: NoticeProps): React.ReactElement;

export interface ProgressProps { label: string; value: number; max?: number }
export declare function Progress(props: ProgressProps): React.ReactElement;

export interface StatTileProps { label: string; value: React.ReactNode; suffix?: string; note?: string; tone?: 'default' | 'brand' | 'danger' }
export declare function StatTile(props: StatTileProps): React.ReactElement;

export interface DataTableColumn { key: string; label: string; align?: 'left' | 'right' }
export interface DataTableProps { columns: DataTableColumn[]; rows: Array<Record<string, React.ReactNode> & { id?: string }>; caption?: string }
export declare function DataTable(props: DataTableProps): React.ReactElement;

export interface CardProps { title?: string; action?: React.ReactNode; tone?: 'default' | 'tint'; children?: React.ReactNode; className?: string }
export declare function Card(props: CardProps): React.ReactElement;

export interface SectionHeadingProps { eyebrow?: string; title: string; rule?: boolean; children?: React.ReactNode }
export declare function SectionHeading(props: SectionHeadingProps): React.ReactElement;

export interface SideNavItem { label: string; href?: string; current?: boolean }
export interface SideNavProps { logo?: string; church?: string; app?: string; label?: string; groups: Array<{ label: string; items: SideNavItem[] }> }
export declare function SideNav(props: SideNavProps): React.ReactElement;

export interface TextFieldProps extends React.InputHTMLAttributes<HTMLInputElement> { id: string; label: string; hint?: string }
export declare function TextField(props: TextFieldProps): React.ReactElement;

export interface SelectFieldProps extends React.SelectHTMLAttributes<HTMLSelectElement> { id: string; label: string; hint?: string; options: Array<string | { value: string; label: string }> }
export declare function SelectField(props: SelectFieldProps): React.ReactElement;

export interface CheckboxProps extends React.InputHTMLAttributes<HTMLInputElement> { label: string }
export declare function Checkbox(props: CheckboxProps): React.ReactElement;

export interface SegmentedProps { label: string; options: string[]; value?: string; defaultValue?: string; onChange?: (value: string) => void }
export declare function Segmented(props: SegmentedProps): React.ReactElement;

export interface StepperStep { label: string; note?: string; state?: 'done' | 'current' | 'todo' }
export interface StepperProps { label?: string; steps: StepperStep[] }
export declare function Stepper(props: StepperProps): React.ReactElement;

export interface RestrictedPanelProps { title?: string; audience: string; children?: React.ReactNode }
export declare function RestrictedPanel(props: RestrictedPanelProps): React.ReactElement;

export interface ServiceGridRow { activity: string; sub?: string; start: string; minutes: number; led: string; person?: boolean }
export interface ServiceGridProps { title?: string; rows: ServiceGridRow[] }
export declare function ServiceGrid(props: ServiceGridProps): React.ReactElement;

export interface DateBlockProps { day: string | number; month: string }
export declare function DateBlock(props: DateBlockProps): React.ReactElement;

export interface NewsletterHeaderProps { logo?: string; church?: string; title?: string; subtitle?: string }
export declare function NewsletterHeader(props: NewsletterHeaderProps): React.ReactElement;

export interface GatheringRowProps { day: string | number; month: string; tag?: string; title: string; text?: string; going?: number; rsvpLabel?: string }
export declare function GatheringRow(props: GatheringRowProps): React.ReactElement;

export interface WinsBannerProps { label?: string; children: React.ReactNode }
export declare function WinsBanner(props: WinsBannerProps): React.ReactElement;

export interface EventPostProps { tag?: string; title: string; date: string; time?: string; place?: string; footer?: string }
export declare function EventPost(props: EventPostProps): React.ReactElement;

export interface SlideProps { kind?: 'title' | 'content'; eyebrow?: string; title: string; subtitle?: string; points?: string[]; footer?: string }
export declare function Slide(props: SlideProps): React.ReactElement;

export type ValueLetter = 'A' | 'S' | 'H' | 'L' | 'I' | 'E';
export interface CoreValue { letter: ValueLetter; name: string; behaviour: string }
export interface ValueTagProps { letter: ValueLetter; name?: string }
export declare function ValueTag(props: ValueTagProps): React.ReactElement;
export interface ValuesStripProps { values?: CoreValue[]; compact?: boolean; label?: string }
export declare function ValuesStrip(props: ValuesStripProps): React.ReactElement;
export declare const ASHLIE: CoreValue[];

declare global {
  interface Window {
    TEC: {
      Icon: typeof Icon; Button: typeof Button; Chip: typeof Chip; Notice: typeof Notice; Progress: typeof Progress;
      StatTile: typeof StatTile; DataTable: typeof DataTable; Card: typeof Card; SectionHeading: typeof SectionHeading;
      SideNav: typeof SideNav; TextField: typeof TextField; SelectField: typeof SelectField; Checkbox: typeof Checkbox;
      Segmented: typeof Segmented; Stepper: typeof Stepper; RestrictedPanel: typeof RestrictedPanel;
      ServiceGrid: typeof ServiceGrid; DateBlock: typeof DateBlock; NewsletterHeader: typeof NewsletterHeader;
      GatheringRow: typeof GatheringRow; WinsBanner: typeof WinsBanner; EventPost: typeof EventPost; Slide: typeof Slide;
      ValueTag: typeof ValueTag; ValuesStrip: typeof ValuesStrip; ASHLIE: CoreValue[];
    };
  }
}
